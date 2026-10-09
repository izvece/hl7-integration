-- Mirth bekommt eine eigene Datenbank fuer seinen internen Zustand
-- (Kanal-Konfiguration, Message-Store, Statistiken). Strikt getrennt von den
-- klinischen Daten in der Datenbank "hl7": ein Mirth-Upgrade, das seine
-- eigenen Tabellen umbaut, kann damit die Patientendaten nicht anfassen.
CREATE DATABASE mirthdb OWNER mirth;
COMMENT ON DATABASE mirthdb IS 'Interner Zustand von Mirth Connect - keine klinischen Daten';
