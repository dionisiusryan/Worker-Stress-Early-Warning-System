from sqlalchemy import create_engine, Column, Integer, String, Float, DateTime
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker
import datetime
import hashlib

# Membuat file database lokal bernama commute_mind.db di folder server
SQLALCHEMY_DATABASE_URL = "sqlite:///./commute_mind.db"

engine = create_engine(
    SQLALCHEMY_DATABASE_URL, connect_args={"check_same_thread": False}
)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

Base = declarative_base()

# Tabel user (username + PIN hash)
class UserModel(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, index=True)
    username = Column(String, unique=True, index=True, nullable=False)
    pin_hash = Column(String, nullable=False)
    created_at = Column(DateTime, default=datetime.datetime.utcnow)

# Tabel untuk menyimpan data log komuter & kerja harian user
class CommuteLogModel(Base):
    __tablename__ = "commute_logs"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(String, index=True)
    durasi_komuter_menit = Column(Integer)
    durasi_kerja_menit = Column(Integer)
    jarak_dari_rumah_km = Column(Float)
    status_perjalanan = Column(String) # 'normal' atau 'cuti'
    created_at = Column(DateTime, default=datetime.datetime.utcnow)

# Fungsi inisialisasi database
def init_db():
    Base.metadata.create_all(bind=engine)

def hash_pin(pin: str) -> str:
    return hashlib.sha256(pin.encode()).hexdigest()