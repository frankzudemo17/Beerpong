# 🍺 Bierpong Turnier-Manager

Web-App zum Verwalten von Bierpong-Turnieren. Single-File-Frontend auf Supabase-Backend.

## Features (Stand jetzt)

- 🔐 Auth + Rollen-System (Superadmin, Admin, Punkterichter, Kassenwart, Zuschauer)
- ✉️ Einladungs-System mit QR-Code-Generierung
- 🏆 Turniere anlegen (Single/Double-Elim, Gruppe+KO, Liga)
- 👥 Teams pro Turnier mit Seeds verwalten

Roadmap & Details: siehe [HANDOFF.md](HANDOFF.md).

## Stack

- **Frontend:** 1× `index.html` (HTML + CSS + Vanilla JS, CDN-Libs)
- **Backend:** Supabase (Postgres + Auth + RLS)
- **Libs:** supabase-js v2, qrcodejs, Google Fonts (Anton / DM Sans / Space Mono)
- **Hosting:** GitHub Pages (geplant)

## Setup

### 1. Supabase

1. Neues Projekt auf [supabase.com](https://supabase.com) anlegen (Region: **Central EU / Frankfurt**).
2. `bierpong_schema.sql` im SQL-Editor einmal komplett ausführen.
3. Unter **Project Settings → API** die **Project URL** und den **publishable / anon Key** kopieren.
4. In `index.html` ganz oben im `<script>` beide Werte eintragen:
   ```js
   const SUPABASE_URL      = "https://DEIN-PROJEKT.supabase.co";
   const SUPABASE_ANON_KEY = "DEIN_PUBLISHABLE_KEY";
   ```
5. **Bootstrap** (einmalig): im SQL-Editor mit deiner Registrierungs-Mail ausführen:
   ```sql
   insert into public.user_roles (user_id, role)
   select id, 'superadmin' from auth.users where email = 'DEINE@email.de';
   ```

### 2. Auth-Einstellungen

Im Supabase-Dashboard → **Authentication**:

- „Allow new users to sign up" aktivieren
- **URL Configuration** → Site URL = deine GitHub-Pages-URL eintragen
- **CAPTCHA** empfohlen (Attack Protection)

### 3. Lokal testen

Einfach `index.html` im Browser öffnen (Doppelklick reicht). Für GitHub Pages später die Datei ins Repo-Root pushen.

## Sicherheit

- RLS-Policies sind die **einzige** Wahrheit — das Frontend versteckt nur, die DB entscheidet.
- Der `anon`/publishable Key ist **öffentlich-by-design** und darf im Repo liegen.
- Der `service_role`/`secret` Key hat im Frontend **nichts verloren**. Niemals.

## Dateien

| Datei | Zweck |
|---|---|
| `index.html` | Komplettes Frontend (Single File) |
| `bierpong_schema.sql` | DB-Schema + RLS-Policies |
| `HANDOFF.md` | Vollständiger Projektstand & Roadmap |
| `.gitignore` | Sauberes Repo (kein Editor-/OS-Müll) |
| `README.md` | Diese Datei |

## Lizenz

Privat. Eigentum von Rezo.