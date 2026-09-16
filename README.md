# WOSWAS — Worker Stress Early Warning System

> Aplikasi mobile berbasis AI untuk deteksi dini, analisis, dan pendampingan stres kerja — dengan seluruh pemrosesan AI berjalan **on-premise** demi menjaga privasi data pengguna.

**Kategori Hackathon:** Healthcare & Wellbeing
**Event:** Hackathon Hactiv8 x IBM

---

## 📖 Tentang Proyek

WOSWAS lahir dari pengalaman nyata pekerja komuter yang baru menyadari tingkat stresnya tinggi setelah menjalani Medical Check-Up (MCU) — padahal gejalanya (pegal, lelah, kurang fokus) selama ini dianggap hal biasa dalam bekerja.

Aplikasi ini membantu pengguna:
- Memantau akumulasi jam kerja dan waktu perjalanan (commuting) sebagai indikator awal beban kerja.
- Melakukan skrining mandiri menggunakan instrumen **DASS-21** yang tervalidasi.
- Mendapatkan analisis dan rekomendasi personal dari AI.
- Menerima **peringatan dini** saat tingkat stres terdeteksi di atas 70%.
- Mencurahkan isi hati (curhat) dengan aman, karena data diproses sepenuhnya di server sendiri (on-premise), bukan di cloud pihak ketiga.

---

## ✨ Fitur Utama

| Fitur | Deskripsi |
|---|---|
| Pemantauan Akumulasi Aktivitas | Mencatat akumulasi jam kerja & waktu perjalanan harian |
| Tes Mandiri DASS-21 | Skrining stres, kecemasan, dan depresi, dapat diakses kapan saja |
| Analisis & Rekomendasi AI | Perhitungan tingkat stres beserta riwayat & rekomendasi tindak lanjut |
| Sistem Peringatan Dini | Notifikasi otomatis saat tingkat stres > 70% |
| Ruang Curhat Aman | Diproses & disimpan on-premise, tidak mengalir ke pihak ketiga |
| Riwayat & Tren Stres | Melihat perkembangan tingkat stres dari waktu ke waktu |

---

## 🏗️ Arsitektur & Tech Stack

| Komponen | Peran |
|---|---|
| **IBM BOB** | Platform pembuat kode (code generation) |
| **Langflow** | Orkestrasi prompting AI |
| **Ollama (Llama 3)** | LLM yang berjalan offline / on-premise |
| **Flutter** | Front-end aplikasi mobile |
| **FastAPI (Python)** | Back-end |
| **Android Studio** | Build APK |

### Alur Integrasi

```
User
  │
  ▼
Aplikasi Flutter (Front End)
  │
  ▼
Backend FastAPI (dibangun dengan IBM BOB)
  │
  ▼
Langflow (prompting AI)
  │
  ▼
LLM Ollama (on-premise)
  │
  ▼
Hasil analisis & rekomendasi → ditampilkan ke User
```

Karena Langflow dan Ollama dijalankan pada server lokal, seluruh data sensitif (hasil tes & curhatan) tidak pernah meninggalkan infrastruktur yang dikendalikan sendiri.

---

## 🚀 Instalasi & Menjalankan Aplikasi

### 1. Persiapan Server (dijalankan di server/lokal)

Pastikan sudah terinstal:
- **Langflow**
- **Ollama** (model `llama3`)
- Script backend `server_lokal.py`

### 2. Menjalankan Service di Server

```bash
# Jalankan model LLM
ollama run llama3

# Jalankan Langflow
langflow run

# Masuk ke direktori backend, lalu jalankan server FastAPI
cd <direktori server_lokal.py>
py -m uvicorn server_lokal:app --host 0.0.0.0 --port 8000 --reload
```

### 3. Menjalankan Aplikasi di Perangkat Pengguna

```bash
# Install APK ke perangkat Android
Install apk -> buka apk
```

Setelah ketiga service di atas berjalan dan APK terpasang, aplikasi WOSWAS siap digunakan.

---

## 💰 Model Bisnis & Monetisasi

Proyek ini mendukung model **B2C** dan **B2B** sekaligus:

| Model | Sumber Pendapatan |
|---|---|
| **B2C – Freemium** | In-app purchase melalui Google Play Store (riwayat tak terbatas, analisis lanjutan, laporan personal) |
| **B2C – Iklan** | Iklan non-intrusif pada versi gratis |
| **B2B – Enterprise On-Premise** | Lisensi premium untuk perusahaan yang ingin data karyawannya (curhat, hasil tes, analisis AI) disimpan pada server milik mereka sendiri, demi keamanan & kepatuhan data |

---

## 🎯 Kesesuaian dengan Kriteria Penilaian

- **Problem Clarity & Relevance** — masalah stres kerja nyata, personal, dan terdokumentasi.
- **Innovation, Creativity, Feasibility & Monetization** — menggabungkan pemantauan aktivitas, skrining klinis, dan AI on-premise dalam satu sistem, dengan model bisnis B2C + B2B yang jelas.
- **User Impact & Benefits** — deteksi dini, akses skrining tanpa hambatan, rekomendasi personal, rasa aman curhat.
- **Technical Execution & Prototype Functionality** — prototipe end-to-end yang dapat langsung didemonstrasikan.
- **Responsible AI Implementation** — data diproses on-premise, AI diposisikan sebagai alat deteksi dini (bukan pengganti diagnosis profesional), rekomendasi transparan dan dapat ditelusuri.

---

## 👥 Tim

- **Dionisius Riyan Edlianto**

## 📄 Lisensi

Proyek ini dikembangkan untuk keperluan Hackathon Hactiv8 x IBM.

## APK & Demo Video
https://drive.google.com/drive/folders/1tG4IclGNoj9BBodQVQRdqTbDZ-Xi3tZT?usp=sharing

## Screenshoot Project







<img width="216" height="420" alt="01-Dashboard-AI-Recomendation" src="https://github.com/user-attachments/assets/03be8913-8410-40d3-9b51-5850a1406309" />
<img width="216" height="420" alt="02-Screening-DASS21" src="https://github.com/user-attachments/assets/af4dabfd-befe-49ee-a873-53361f86bfba" />
<img width="216" height="420" alt="03-Hasil Rekomendasi- AI Part 1" src="https://github.com/user-attachments/assets/ff3dcf8c-b60b-4465-8939-d9337f14fe93" />
<img width="216" height="420" alt="04-Hasil Rekomendasi - AI - part2" src="https://github.com/user-attachments/assets/5a1ce12e-610f-4dc2-a786-04b29640922c" />
<img width="216" height="420" alt="05- Chatbot-AI-Psikolog" src="https://github.com/user-attachments/assets/4362106e-2e10-45cf-94c2-392212e367c5" />
<img width="216" height="420" alt="06-History-riwayat perjalan-dan-tingkat-stress" src="https://github.com/user-attachments/assets/bbb5aecf-75ed-40a0-84ee-7809c0fbe6e6" />
<img width="216" height="420" alt="07-Setting" src="https://github.com/user-attachments/assets/4c32a25d-4094-439d-b319-0a9171b231a0" />
<img width="216" height="420" alt="08-logs" src="https://github.com/user-attachments/assets/fa8c028d-bb95-4fa1-9cb0-cfd46200d309" />
