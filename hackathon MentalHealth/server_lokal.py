import socket
from datetime import datetime
from typing import Dict, List, Optional
from fastapi import FastAPI, Depends
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import requests
import uvicorn
from zeroconf import ServiceInfo, Zeroconf

# --- IMPORT DATABASE LOCAL ---
from sqlalchemy.orm import Session
from database import SessionLocal, init_db, CommuteLogModel, UserModel, hash_pin

# Inisialisasi FastAPI
app = FastAPI(
    title="Commute Mind Companion Gateway",
    description="Backend lokal penerima data pasif komuter, pemicu DASS-21 & AI Orchestrator terintegrasi SQLite",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

LANGFLOW_URL = "http://127.0.0.1:7860/api/v1/run/0006294e-0b61-4f5b-bdb2-1225bee32b74?stream=false"
LANGFLOW_API_KEY = "sk-kmp-eOM6ZNS-STp6gIjdcCyt-Gh2-ZSPcN8dG4ZvUAc"

# Cache di memori untuk pendaftaran instan
REGISTERED_USERS: Dict[str, dict] = {}  


# --- STARTUP EVENT (Menyiapkan Database Saat Server Nyala) ---
@app.on_event("startup")
def startup_event():
    print("[INFO] Melakukan inisialisasi Database SQLite lokal...")
    init_db()
    print("[INFO] Database siap digunakan!")

# --- DEPENDENCY DATABASE ---
def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


# --- SKEMA VALIDASI (Pydantic Models) ---
class RegisterSchema(BaseModel):
    user_id: str
    pin: str

class LoginSchema(BaseModel):
    user_id: str
    pin: str

class CheckUsernameSchema(BaseModel):
    user_id: str

class CommuteData(BaseModel):
    user_id: str
    durasi_komuter_menit: int
    durasi_kerja_menit: int
    jarak_dari_rumah_km: Optional[float] = 0.0  
    status_perjalanan: Optional[str] = "normal"   

class Dass21Data(BaseModel):
    user_id: str
    stress_score: int
    stress_level: str
    anxiety_score: int
    anxiety_level: str
    depression_score: int
    depression_level: str

class HistoryData(BaseModel):
    user_id: str
    total_stress_percentage: float
    total_days: int

class ChatCurhatData(BaseModel):
    user_id: str
    message: str
    chat_history: Optional[List[dict]] = []


def get_local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
    except Exception:
        ip = "127.0.0.1"
    finally:
        s.close()
    return ip


def clean_markdown_bold(text: str) -> str:
    if not text:
        return ""
    return text.replace("**", "").replace("*", "")


def call_langflow_unified(prompt_text: str) -> Optional[str]:
    payload = {
        "input_value": prompt_text,
        "output_type": "chat",
        "input_type": "chat",
        "tweaks": {}
    }
    
    headers = {"Content-Type": "application/json"}
    
    if LANGFLOW_API_KEY and not LANGFLOW_API_KEY.startswith("sk-xxxx"):
        headers["x-api-key"] = LANGFLOW_API_KEY
        headers["Authorization"] = f"Bearer {LANGFLOW_API_KEY}"

    try:
        print(f"\n[INFO] Mengirim prompt ke Langflow...")
        req = requests.post(LANGFLOW_URL, json=payload, headers=headers, timeout=120)
        print(f"[INFO] Langflow Status Code: {req.status_code}")

        if req.status_code == 200:
            res_data = req.json()
            outputs = res_data.get("outputs", [])
            if outputs:
                first_out = outputs[0].get("outputs", [])
                if first_out:
                    results = first_out[0].get("results", {})
                    message = results.get("message", {})
                    
                    if isinstance(message, dict):
                        ai_text = message.get("text") or message.get("text", {}).get("data", {}).get("text")
                    else:
                        ai_text = str(message)

                    if not ai_text:
                        ai_text = results.get("text", "")

                    if ai_text:
                        print(f"[BERHASIL] AI Balas: {ai_text}\n")
                        return clean_markdown_bold(ai_text)
        else:
            print(f"[ERROR {req.status_code}] Body: {req.text}")
            
    except Exception as e:
        print(f"[ERROR] Gagal koneksi ke Langflow: {e}")
        
    return None


# --- 1a. ENDPOINT: REGISTER USER BARU ---
@app.post("/api/v1/register")
async def register_user(data: RegisterSchema, db: Session = Depends(get_db)):
    username = data.user_id.strip()
    if not username or len(data.pin) != 4:
        return {"success": False, "message": "Username atau PIN tidak valid."}

    existing = db.query(UserModel).filter(UserModel.username == username).first()
    if existing:
        return {"success": False, "message": "Username sudah digunakan."}

    new_user = UserModel(username=username, pin_hash=hash_pin(data.pin))
    db.add(new_user)
    db.commit()
    REGISTERED_USERS[username] = {"last_active": str(datetime.now())}
    return {"success": True, "message": "Registrasi berhasil."}


# --- 1b. ENDPOINT: LOGIN USER ---
@app.post("/api/v1/login")
async def login_user(data: LoginSchema, db: Session = Depends(get_db)):
    username = data.user_id.strip()
    user = db.query(UserModel).filter(UserModel.username == username).first()
    if not user:
        return {"success": False, "message": "Username tidak ditemukan."}
    if user.pin_hash != hash_pin(data.pin):
        return {"success": False, "message": "PIN salah."}
    REGISTERED_USERS[username] = {"last_active": str(datetime.now())}
    return {"success": True, "message": "Login berhasil."}


# --- 1c. ENDPOINT: CEK KEUNIKAN USERNAME (legacy, tetap ada) ---
@app.post("/api/v1/check-username")
async def check_username(data: CheckUsernameSchema, db: Session = Depends(get_db)):
    username = data.user_id.strip()
    existing = db.query(UserModel).filter(UserModel.username == username).first()
    if existing:
        return {"is_available": False, "message": "Username sudah digunakan."}
    return {"is_available": True, "message": "Username tersedia."}


# --- 2. ENDPOINT HARIAN: SIMPAN LOG KE DATABASE LOKAL ---
@app.post("/api/v1/commute-log")
async def receive_commute_log(data: CommuteData, db: Session = Depends(get_db)):
    REGISTERED_USERS[data.user_id] = {"last_active": str(datetime.now())}
    
    today_weekday = datetime.now().weekday()  # 5 = Sabtu, 6 = Minggu
    is_weekend = today_weekday >= 5
    is_off_day = is_weekend or data.status_perjalanan in ["cuti", "sakit"]

    # Lewati pencatatan beban di database jika sedang libur
    if is_off_day:
        return {
            "status": "ignored",
            "notification_title": "Hari Istirahat / Libur 🌿",
            "notification_body": "Status cuti/libur/akhir pekan terdeteksi. Stres dan beban komuter dinolkan.",
            "trigger_dass21": False,
            "ai_message": (
                f"Halo {data.user_id}! Hari ini terpantau sebagai hari libur, cuti, atau akhir pekan.\n\n"
                "• Kalkulasi stres dan beban komuter ditiadakan agar datamu tetap bersih.\n"
                "• Nikmati waktu istirahatmu dengan tenang hari ini."
            ),
        }

    durasi_komuter_jam = round(data.durasi_komuter_menit / 60, 1)
    durasi_kerja_jam = round(data.durasi_kerja_menit / 60, 1)
    
    # Jika dinas luar kota, berikan bobot tambahan pada beban perjalanan
    if data.status_perjalanan == "luar_kota":
        total_beban_jam = round((data.durasi_komuter_menit * 1.5 + data.durasi_kerja_menit) / 60, 1)
    else:
        total_beban_jam = round((data.durasi_komuter_menit + data.durasi_kerja_menit) / 60, 1)

    user_logs_db = db.query(CommuteLogModel).filter(CommuteLogModel.user_id == data.user_id).all()

    # Validasi jika data baru instal (0 Menit & 0 Jam) di hari kerja
    if data.durasi_komuter_menit == 0 and data.durasi_kerja_menit == 0:
        return {
            "status": "success",
            "notification_title": "Selamat Datang! 🌿",
            "notification_body": "Aplikasi siap memantau perjalanan komutermu.",
            "trigger_dass21": False,
            "data": {
                "user_id": data.user_id,
                "total_beban_jam": 0,
                "total_hari_monitoring": len(user_logs_db),
                "status_risiko": "BELUM_ADA_DATA",
            },
            "ai_message": (
                f"Halo {data.user_id}! Kamu terpantau sudah masuk kerja hari ini.\n\n"
                "• Aplikasi aktif memantau perjalanan dan jam kerjamu secara pasif.\n"
                "• Lakukan aktivitasmu seperti biasa, data akan terakumulasi otomatis."
            ),
        }

    # SIMPAN KE DATABASE SQLITE
    new_log = CommuteLogModel(
        user_id=data.user_id,
        durasi_komuter_menit=data.durasi_komuter_menit,
        durasi_kerja_menit=data.durasi_kerja_menit,
        jarak_dari_rumah_km=data.jarak_dari_rumah_km,
        status_perjalanan=data.status_perjalanan
    )
    db.add(new_log)
    db.commit()
    db.refresh(new_log)

    # Ambil ulang data dari database untuk perhitungan threshold
    user_logs_db = db.query(CommuteLogModel).filter(CommuteLogModel.user_id == data.user_id).all()
    total_hari_monitoring = len(user_logs_db)
    
    # Cek rekam jejak 30 hari terakhir dari DB
    recent_logs = user_logs_db[-30:] if total_hari_monitoring > 30 else user_logs_db
    hari_beban_tinggi = 0
    for log in recent_logs:
        kom_jam = log.durasi_komuter_menit / 60
        ker_jam = log.durasi_kerja_menit / 60
        beban = (log.durasi_komuter_menit * 1.5 + log.durasi_kerja_menit) / 60 if log.status_perjalanan == "luar_kota" else kom_jam + ker_jam
        if beban >= 11.0:
            hari_beban_tinggi += 1

    perlu_dass21 = (total_beban_jam >= 12.0) or (hari_beban_tinggi >= 5)
    status_risiko = "RISIKO_BURNOUT_KUMULATIF" if perlu_dass21 else "DALAM_BATAS_NORMAL"

    # AI Prompt — dibatasi ketat ke topik komuter & kesehatan mental
    prompt = (
        f"Kamu adalah asisten kesehatan mental untuk pekerja komuter. "
        f"HANYA boleh membahas topik: kesehatan mental, pemulihan fisik setelah perjalanan, "
        f"manajemen kelelahan, istirahat, dan tips rutinitas harian pekerja komuter. "
        f"DILARANG KERAS membahas keuangan, investasi, gaji, utang, atau topik di luar kesehatan mental komuter.\n\n"
        f"Gunakan Bahasa Indonesia santai dan sangat ringkas.\n"
        f"Data Klien ({data.user_id}):\n"
        f"- Durasi Perjalanan Hari Ini: {data.durasi_komuter_menit} menit\n"
        f"- Jam Kerja Hari Ini: {durasi_kerja_jam} jam\n"
        f"- Status Risiko Burnout: {status_risiko}\n\n"
        f"PERINTAH:\n"
        f"Tuliskan saran pemulihan mental pasca-komuter dengan format:\n"
        f"1 kalimat empati hangat tentang kelelahan perjalanan/kerja + 3 poin saran pemulihan fisik/mental super singkat (maksimal 10 kata per poin).\n"
        f"DILARANG membuat paragraf panjang, DILARANG bertanya balik, DILARANG menyebut topik keuangan, dan DILARANG menggunakan simbol bold (**)."
    )

    ai_response = call_langflow_unified(prompt)

    if not ai_response:
        ai_response = (
            f"🌿 Terima kasih sudah bertahan melewati {durasi_kerja_jam} jam kerja dan perjalanan hari ini.\n\n"
            "Saran pemulihan singkat malam ini:\n"
            "• Istirahatkan mata dari layar HP/laptop minimal 30 menit.\n"
            "• Lakukan peregangan leher dan pundak secara perlahan.\n"
            "• Minum air hangat dan persiapkan waktu tidur yang cukup."
        )

    return {
        "status": "success",
        "notification_title": "Analisis AI Siap! 🤖",
        "notification_body": "Hasil evaluasi komuter harian Anda siap dibaca.",
        "trigger_dass21": perlu_dass21,
        "data": {
            "user_id": data.user_id,
            "total_beban_jam": total_beban_jam,
            "total_hari_monitoring": total_hari_monitoring,
            "status_risiko": status_risiko,
        },
        "ai_message": ai_response,
    }


# --- 3. ENDPOINT DASS-21 ---
@app.post("/api/v1/dass21-recommendation")
async def get_dass21_recommendation(data: Dass21Data):
    is_severe = any(
        level in ["Berat", "Sangat Berat"] 
        for level in [data.stress_level, data.anxiety_level, data.depression_level]
    )

    is_all_normal = (
        data.stress_level == "Normal" and 
        data.anxiety_level == "Normal" and 
        data.depression_level == "Normal"
    )

    if is_all_normal:
        prompt_instruction = (
            "Kondisi klien SANGAT SEHAT & NORMAL (semua skor DASS-21 dalam batas normal).\n"
            "Berikan apresiasi positif dan ucapan selamat karena berhasil menjaga kesehatan mentalnya, "
            "serta 2 tips singkat untuk mempertahankan kondisi ini. "
            "DILARANG membahas stres, kecemasan berlebihan, atau kalimat 'kamu tidak sendiri'."
        )
    elif is_severe:
        prompt_instruction = (
            "Kondisi klien tergolong BERAT / SANGAT BERAT berdasarkan skor DASS-21.\n"
            "Berikan empati hangat, edukasi bahwa aplikasi ini hanya instrumen deteksi awal, "
            "dan rekomendasikan secara halus untuk konsultasi langsung dengan Psikolog atau Psikiater profesional."
        )
    else:
        prompt_instruction = (
            "Kondisi klien mengalami gejala ringan/sedang berdasarkan skor DASS-21. "
            "Berikan empati hangat dan 2-3 langkah relaksasi mandiri yang praktis dan spesifik."
        )

    prompt = (
        f"Kamu adalah asisten kesehatan mental. "
        f"HANYA boleh membahas topik yang berkaitan langsung dengan hasil skor DASS-21 ini: "
        f"kondisi psikologis, stres, kecemasan, depresi, dan cara pemulihannya. "
        f"DILARANG KERAS membahas keuangan, uang, pekerjaan spesifik, atau topik apapun "
        f"yang tidak berkaitan langsung dengan hasil skrining DASS-21 ini.\n\n"
        f"Jawab singkat dan ringkas (maksimal 3-4 kalimat) dalam Bahasa Indonesia santai.\n"
        f"Hasil DASS-21 untuk {data.user_id}:\n"
        f"- Stres: {data.stress_score} poin ({data.stress_level})\n"
        f"- Kecemasan: {data.anxiety_score} poin ({data.anxiety_level})\n"
        f"- Depresi: {data.depression_score} poin ({data.depression_level})\n\n"
        f"INSTRUKSI UTAMA:\n"
        f"{prompt_instruction}\n"
        f"DILARANG menggunakan tanda bold (**). DILARANG membahas topik di luar skor DASS-21 di atas."
    )

    ai_response = call_langflow_unified(prompt)

    if not ai_response:
        if is_all_normal:
            ai_response = (
                f"🌱 Luar biasa! Hasil DASS-21 kamu menunjukkan kondisi emosional yang sangat stabil dan dalam batas normal.\n\n"
                f"Saran untuk menjaga energi positif ini:\n"
                f"• Pertahankan pola tidur teratur dan nutrisi harianmu.\n"
                f"• Sempatkan melakukan hobi favorit di akhir pekan sebagai bentuk apresiasi diri."
            )
        elif is_severe:
            ai_response = (
                f"🚨 SKOR DASS-21 MENUNJUKKAN TINGKAT BERAT / SANGAT BERAT\n\n"
                f"💡 Catatan Penting:\n"
                f"Aplikasi ini hanya berfungsi sebagai alat deteksi & skrining awal, bukan penentu diagnosis medis.\n\n"
                f"🩺 Rekomendasi Penanganan:\n"
                f"Sangat disarankan untuk berkonsultasi langsung dengan Psikolog Klinis atau Psikiater profesional agar mendapatkan penanganan yang tepat."
            )
        else:
            ai_response = (
                f"🌿 Kondisi psikologis kamu relatif stabil dengan sedikit keletihan ringan.\n"
                f"Coba luangkan waktu 10-15 menit untuk istirahat sejenak dari layar HP/laptop dan lakukan relaksasi napas."
            )

    return {"status": "success", "recommendation": ai_response}


# --- 4. ENDPOINT HISTORI KUMULATIF ---
@app.post("/api/v1/history-recommendation")
async def get_history_recommendation(data: HistoryData):
    is_high_risk = data.total_stress_percentage > 70.0

    prompt = (
        f"Jawab singkat dalam Bahasa Indonesia.\n"
        f"Data Tren Kumulatif Klien {data.user_id}:\n"
        f"- Tingkat Stres Kumulatif: {data.total_stress_percentage}%\n"
        f"- Hari Pemantauan: {data.total_days} hari\n\n"
        f"PERINTAH UTAMA:\n"
        f"{'Tingkat stres kumulatif MELEBIHI BATAS AMAN (>70% / Berat). Wajib beri tahu bahwa AI ini hanya skrining awal dan rekomendasikan konsultasi ke Psikolog/Psikiater profesional.' if is_high_risk else 'Berikan 2 saran singkat penyesuaian gaya hidup.'}\n"
        f"DILARANG menggunakan simbol bold (**)."
    )

    ai_response = call_langflow_unified(prompt)

    if not ai_response:
        if is_high_risk:
            ai_response = (
                f"📊 EVALUASI TREN KRONIS: TINGKAT STRES {data.total_stress_percentage}% (KATEGORI TINGGI)\n\n"
                f"Tingkat beban komuter dan akumulasi stres harian Anda dalam {data.total_days} hari terakhir sudah melebihi batas toleransi aman.\n\n"
                f"⚠️ Catatan Deteksi Awal:\n"
                f"Pemantauan harian ini adalah instrumen skrining awal.\n\n"
                f"🩺 Tindakan Disarankan:\n"
                f"Sangat disarankan untuk menjadwalkan konsul dengan Psikolog atau Psikiater profesional guna mencegah risiko burnout yang berkelanjutan."
            )
        else:
            ai_response = (
                f"📊 Tren stres kumulatif Anda terpantau di angka {data.total_stress_percentage}% selama {data.total_days} hari pemantauan.\n"
                f"Cobalah untuk menerapkan batas tegas antara jam kerja dan waktu istirahat pribadi."
            )

    return {"status": "success", "recommendation": ai_response}


# Kata-kata yang mengindikasikan situasi negatif/buruk — dipakai untuk mendeteksi
# apakah pesan user mengandung konteks kehilangan, masalah, atau hal menyedihkan.
_NEGATIVE_KEYWORDS = [
    "kecurian", "dicuri", "kehilangan", "hilang", "ditipu", "disakiti", "dipecat",
    "resign", "putus", "meninggal", "kecelakaan", "sakit", "hutang", "bangkrut",
    "nggak ada uang", "tidak ada uang", "gak ada uang", "susah", "sedih", "nangis",
    "marah", "kesal", "frustrasi", "stres", "capek banget", "lelah banget",
    "gagal", "tidak bisa", "nggak bisa", "gak bisa", "menyesal", "galau",
]

def _is_negative_message(text: str) -> bool:
    """Deteksi apakah pesan mengandung konteks negatif/masalah."""
    lower = text.lower()
    return any(kw in lower for kw in _NEGATIVE_KEYWORDS)


# --- 5. ENDPOINT CHATBOT CURHAT ---
@app.post("/api/v1/chat-curhat")
async def chat_curhat(data: ChatCurhatData):
    history_text = ""
    if data.chat_history:
        recent_chats = data.chat_history[-4:]
        formatted = []
        for msg in recent_chats:
            role = "Teman" if msg.get("sender") == "user" else "AI"
            text = msg.get("text", "").strip()
            if text and not text.startswith("Obrolan telah dibersihkan"):
                formatted.append(f"{role}: {text}")
        if formatted:
            history_text = "Riwayat Chat Terakhir:\n" + "\n".join(formatted) + "\n\n"

    # Deteksi konteks negatif → tambahkan peringatan eksplisit ke prompt
    is_negative = _is_negative_message(data.message)
    # Cek juga apakah riwayat chat terakhir mengandung konteks negatif
    if not is_negative and data.chat_history:
        last_user_msgs = [
            m.get("text", "") for m in data.chat_history[-3:]
            if m.get("sender") == "user"
        ]
        is_negative = any(_is_negative_message(m) for m in last_user_msgs)

    negative_warning = (
        "PERINGATAN KONTEKS: Pesan ini mengandung situasi negatif/masalah/kehilangan. "
        "DILARANG KERAS merespons dengan kata 'Hebat', 'Wow', 'Keren', 'Luar biasa', atau nada kagum/positif. "
        "Respons HARUS menunjukkan empati terhadap situasi buruk yang dialami.\n\n"
    ) if is_negative else ""

    prompt = (
        f"PERINTAH SANGAT PENTING: BALAS WAJIB HANYA DALAM BAHASA INDONESIA SANTAI/GAUL! "
        f"DILARANG MENGGUNAKAN BAHASA INGGRIS ATAU BAHASA ASING LAINNYA!\n\n"
        f"{negative_warning}"
        f"{history_text}"
        f"Pesan Baru: '{data.message}'\n\n"
        f"INSTRUKSI BALASAN (WAJIB DIIKUTI SEMUA):\n"
        f"- Tanggapi ISI SPESIFIK pesan di atas — jangan generalisir atau asumsikan perasaan yang tidak disebutkan.\n"
        f"- JIKA pesan mengandung situasi negatif, kehilangan, atau masalah (kecurian, ditipu, disakiti, kehilangan uang, dll): "
        f"tunjukkan empati yang sesuai situasi tersebut, JANGAN katakan 'Hebat', 'Wow', atau kata yang bernada positif/kagum.\n"
        f"- Maksimal 2-3 kalimat saja. Jangan menggurui dan jangan kasih daftar solusi kecuali diminta.\n"
        f"- Bahasa santai, akrab (pakai 'aku' dan 'kamu'). Boleh tanya balik SATU pertanyaan natural jika itu bikin obrolan lebih lanjut.\n"
        f"- DILARANG pakai kalimat pembuka template seperti 'Aku ngerti kamu lagi...' atau 'Aku nggak akan ninggalin kamu' berulang-ulang.\n"
        f"- DILARANG menyebut nama pengguna dan DILARANG memakai kata kaku atau formal."
    )

    ai_response = call_langflow_unified(prompt)

    if ai_response:
        return {"status": "success", "reply": ai_response}

    return {"status": "success", "reply": "Duh, koneksi ke otakku lagi agak tersendat nih. Coba ulangi pesanku sebentar lagi ya!"}


if __name__ == "__main__":
    local_ip = get_local_ip()

    try:
        hostname = socket.gethostname().lower()
        zeroconf = Zeroconf()
        info = ServiceInfo(
            "_http._tcp.local.",
            "MentalHealthServer._http._tcp.local.",
            addresses=[socket.inet_aton(local_ip)],
            port=8000,
            properties={},
            server=f"{hostname}.local.",
        )
        zeroconf.register_service(info)
    except Exception as e:
        print(f"[Note] Zeroconf mDNS dilewati: {e}")

    print("\n Server Mental Health AI Lokal Aktif!")
    print(f" - Akses via Browser/Web    : http://127.0.0.1:8000/docs")
    print(f" - Akses via Android        : http://{local_ip}:8000/docs\n")

    uvicorn.run(app, host="0.0.0.0", port=8000)