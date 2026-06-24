# Bierpong Turnier-Manager — Projekt-Handoff

> Dieses Dokument ist der vollständige Stand zum Weiterarbeiten (z. B. in Claude Code).
> Tipp: Kopiere es im Repo-Root zusätzlich als **`CLAUDE.md`**, dann lädt Claude Code es
> bei jedem Start automatisch als Projektkontext.

---

## 1. Was das Projekt ist

Eine Web-App zum Verwalten von **Bierpong-Turnieren**. Zweite App auf Basis einer
bestehenden Fotoalbum-App (gleicher Stack, neu aufgebaut). Fotos sind Nebensache;
Kern sind: Turnierplan mit wählbaren Spielmodi, Teams, Spielplan (Tische × Uhrzeiten),
Ergebniseingabe mit **Becherdifferenz**, eine **Kasse** (manuell), eine **Pinnwand**,
Rollen-/Rechteverwaltung und ein **Einladungssystem**.

## 2. Stack & Prinzipien

- **Frontend:** eine einzige `index.html` (HTML + CSS + Vanilla JS, kein Build-Step).
  Läuft als statische Seite, deploybar auf **GitHub Pages**.
- **Backend:** **Supabase** (Postgres + Auth + REST). Kein eigener Server.
- **Externe Libs nur per CDN:** supabase-js v2, qrcodejs, Google Fonts.
- **Sicherheits-Prinzip:** Durchsetzung passiert **immer in den RLS-Policies der DB**,
  nie im JS. Das UI versteckt nur, die Datenbank entscheidet. Der `anon`/publishable
  Key ist öffentlich-by-design und darf im Code/Repo liegen. Der `service_role`/`secret`
  Key gehört **niemals** ins Frontend.
- **Design:** Dark Mode by default. Lagerbier-Gold (`--gold`) + Solo-Cup-Rot (`--cup`)
  auf Aubergine-Nacht-Ton. Display-Font „Anton", Body „DM Sans", Mono „Space Mono".
  10er-Cup-Pyramide als Logo. Token-System steht oben im `<style>`.

## 3. Dateien

| Datei | Zweck |
|---|---|
| `index.html` | Komplettes Frontend. Supabase-Keys stehen oben im `<script>`. |
| `bierpong_schema.sql` | Vollständiges DB-Schema inkl. Tabellen, Funktionen, RLS-Policies. Einmal im Supabase SQL-Editor ausführen. |
| `HANDOFF.md` | Dieses Dokument. |

> Es gibt zusätzlich einen optionalen Patch `bierpong_invite_link.sql` (Registrierung nur
> per Einladungslink über einen „Before User Created"-Hook). **Noch NICHT eingespielt**,
> bewusst nicht Teil des aktuellen Stands — siehe Roadmap, Punkt „Zugang härten".

## 4. Supabase — Projektstand

- Projekt existiert, Region **Central EU (Frankfurt)**.
- **Project URL** und **Publishable Key** sind in `index.html` eingetragen
  (`SUPABASE_URL`, `SUPABASE_ANON_KEY`, ganz oben im `<script>`).
- **Schema:** `bierpong_schema.sql` ist eingespielt.
- **Noch offen:** der **Bootstrap** (sich selbst zum Superadmin machen) — siehe §7.

### Auth-Einstellungen (Dashboard → Authentication)
- Für den ersten Test: „Allow new users to sign up" **an**.
- Nach Deploy: unter **URL Configuration** die GitHub-Pages-URL als **Site URL** und
  bei **Redirect URLs** eintragen — sonst zeigt der Bestätigungslink auf `localhost`.
- Empfohlen: **CAPTCHA** (Attack Protection) gegen Massen-Signup, ggf. E-Mail-Bestätigung.

## 5. Datenmodell (Kurzüberblick)

Alle Tabellen liegen in `public` und haben **RLS aktiv**.

- **`user_roles`** (`user_id`, `role`) — Rolle pro User. Mehrere möglich.
  Enum `app_role`: `superadmin | admin | punkterichter | kassenwart | viewer`.
- **`profiles`** (`id`→auth.users, `display_name`) — wird per Trigger bei Signup angelegt.
- **`invites`** (`code` PK, `role`, `used_by`, `used_at`, `expires_at`, …) — Einladungscodes.
- **`tournaments`** — `format` (`single_elim|double_elim|group_ko|league`), `status`,
  `num_tables`, `third_place` (Spiel um Platz 3), `fifth_seventh` (Trostrunde 5&7, als Bundle),
  `best_of`, `rules_text` (Regelwerk), `config` (jsonb, z. B. Hausregeln).
- **`teams`** (`tournament_id`, `name`, `seed`).
- **`matches`** — `bracket`, `round`, `table_no`, `scheduled_at`, `team_a/b`,
  `score_a/b` (= Becher), `winner`, `status` (`scheduled|live|done`).
- **`payments`** — Kasse: `team_id`, `amount`, `paid`, `method` (`bar|paypal|sonstige`),
  `marked_by`, `marked_at`. Markierung erfolgt **manuell** durch Kassenwart/Admin.
- **`posts`** — Pinnwand.
- **`app_config`** (`key`,`value`) — z. B. PayPal-Link. Nur für eingeloggte User lesbar.

### Funktionen & Views (alle in `bierpong_schema.sql`)
- `has_role(uid, role)`, `is_admin(uid)`, `is_activated(uid)` — `SECURITY DEFINER`-Helfer
  für die Policies (umgehen RLS, damit keine Rekursion entsteht).
  **„Freigeschaltet" = hat mindestens eine Rolle.** Es gibt bewusst KEIN `activated`-Flag,
  das ein User selbst setzen könnte.
- `redeem_invite(code)` — prüft Code serverseitig, vergibt Rolle, markiert als benutzt.
  `SECURITY DEFINER`, damit kein service_role-Key ins Frontend muss.
- `report_result(match, becher_a, becher_b)` — nur Punkterichter/Admin; setzt Score,
  Sieger und Status. Verhindert, dass ein Punkterichter den Spielplan umbaut.
- `handle_new_user()` — Trigger auf `auth.users`, legt Profil an.
- `team_stats` (View, `security_invoker`) — Tabelle mit Siegen und **Becherdifferenz**
  (`cup_diff`). Sortierung z. B. `order by wins desc, cup_diff desc`.

## 6. Rollen & Rechte (so ist es in RLS umgesetzt)

| Rolle | Darf |
|---|---|
| `superadmin` (nur du) | alles, inkl. jede Rolle vergeben (auch `admin`) |
| `admin` | Turniere/Teams/Spielplan verwalten, Einladungen + Rollen vergeben — **außer** admin/superadmin |
| `punkterichter` | nur Ergebnisse melden (`report_result`) |
| `kassenwart` | nur Kasse (`payments`) lesen/schreiben |
| `viewer` | alles Freigeschaltete lesen (Spielplan, Pinnwand) |

Wichtig: **Niemand ohne Rolle sieht irgendwas** — auch nicht den PayPal-Link. Registrieren
allein gibt keinen Datenzugriff; die Rolle (über Einladungscode) ist das Tor.

## 7. Bootstrap — nächster konkreter Schritt

Du bist registriert, aber noch nicht Superadmin (App zeigt „noch nicht freigeschaltet").
Im Supabase **SQL-Editor** einmal ausführen, mit deiner Registrierungs-Mail:

```sql
insert into public.user_roles (user_id, role)
select id, 'superadmin' from auth.users where email = 'DEINE@email.de';
```

Danach App neu laden → du kommst mit der 👑-Superadmin-Pille rein und siehst den
Einladungs-Bereich.

## 8. Auth- & Rollen-Flow im Frontend (wie es jetzt arbeitet)

1. Beim Laden wird ein evtl. Invite-Code aus der URL gelesen (`?code=` oder `#code=`).
2. Kein Login → Auth-Screen (Anmelden/Registrieren).
3. Nach Login: liegt ein Code vor, wird `redeem_invite` aufgerufen (Rolle wird vergeben).
4. `loadRoles()` liest die Rollen aus `user_roles`, `renderApp()` zeigt rollenabhängige Kacheln.
5. Admin kann unter „Einladungen" Codes erzeugen (Insert in `invites`) — Ergebnis: Code +
   Link + QR (clientseitig gerendert).

## 9. Roadmap / nächste Aufgaben (priorisiert)

### ✅ Erledigt
- **1. Turnier anlegen + Teams eintragen** (Admin-Maske). Schreibt in `tournaments` und `teams`.

### Offen
2. **Bracket-Generator + Auto-Scheduler** (Herzstück): aus Format + Teamzahl die `matches`
   erzeugen, auf `num_tables` Tische und Zeitslots verteilen, Konflikte erkennen
   (kein Team gleichzeitig an zwei Tischen). Platzierungsspiele (`third_place`,
   `fifth_seventh`) optional einhängen. Nur in Elimination-Formaten relevant.
3. **Ergebniseingabe-UI** → ruft `report_result` auf. Live-Update via Supabase Realtime.
4. **Tabellen-/Standings-Ansicht** aus `team_stats` (Becherdifferenz als Tiebreaker).
5. **Kasse-UI** → `payments`, manuelles Markieren, Summe, offen/bezahlt. PayPal-Link aus
   `app_config`.
6. **Pinnwand-UI** → `posts`, Realtime.
7. **Beamer-/TV-Modus** (read-only, self-refresh) für den Fernseher auf der Party.
8. **Regelwerk-Tab** aus `tournaments.rules_text`.
9. **Zugang härten (optional):** Registrierung nur per Einladungslink. Dafür existiert der
   Patch `bierpong_invite_link.sql` (macht Invites mehrfach-nutzbar, fügt einen
   „Before User Created"-Hook hinzu, der Signups ohne gültigen Code ablehnt). Erfordert
   zusätzlich Frontend-Anpassungen (Code in Signup-Metadaten, reusable-Checkbox). Reihenfolge
   beachten: erst Bootstrap + Gruppen-Link anlegen, **dann** Hook aktivieren, sonst sperrst
   du dich selbst aus. Hook-Verfügbarkeit auf dem Free-Plan vorher prüfen.

## 10. Konventionen für die Weiterarbeit

- **Eine Datei bleibt vorerst Prinzip**, aber wenn es wächst, sauber in `app.js`,
  `styles.css`, `bracket.js` etc. aufteilen (dann lohnt Claude Code richtig).
- **Keine `localStorage`/`sessionStorage`-Abhängigkeit** für Sicherheitslogik — alles über
  Supabase + RLS.
- **Neue Tabellen:** immer sofort `enable row level security` + Policies, sonst sind sie offen.
- **Neue serverseitige Logik** als `SECURITY DEFINER`-Funktion mit `set search_path = public`.
- Texte/UI auf **Deutsch**, informell.
- **Niemals** den `service_role`/`secret` Key ins Frontend.

## 11. Lokal testen / deployen

- **Lokal:** `index.html` im Browser öffnen (Doppelklick) genügt für die meisten Tests.
- **Deploy:** Datei als `index.html` ins Repo-Root, GitHub Pages → Branch `main`, Ordner `/`.
  Danach Site URL in Supabase eintragen (siehe §4).
- **RLS-Selbsttest** (muss `[]` liefern, unbedeutet ungeloggt = kein Zugriff):
  ```bash
  curl 'https://efuzkhkhdvdtmixbcigz.supabase.co/rest/v1/tournaments?select=*' \
    -H "apikey: <PUBLISHABLE_KEY>"
  ```

---

## 12. Claude Code mit MiniMax-M3 einrichten

Claude Code (Anthropics CLI) lässt sich über zwei Umgebungsvariablen auf MiniMax-M3 umbiegen,
weil MiniMax einen **Anthropic-kompatiblen Endpoint** anbietet.

**a) Claude Code installieren** (Node.js nötig). Siehe offizielle Doku:
`https://docs.claude.com/en/docs/claude-code/overview` (npm-Paket `@anthropic-ai/claude-code`).

**b) MiniMax-API-Key holen:** auf der MiniMax-Developer-Plattform einen **Pay-as-you-go API
Key** erstellen. Achtung: Der **Subscription-/Chat-Key** funktioniert **nicht** gegen den
API-Endpoint — das ist die häufigste 401-Fehlerquelle.

**c) Alte Anthropic-Variablen leeren**, damit nichts kollidiert (z. B. `ANTHROPIC_API_KEY`,
`ANTHROPIC_AUTH_TOKEN`). Falls sie in `~/.bashrc`/`~/.zshrc` exportiert sind, dort entfernen.

**d) `~/.claude/settings.json` bearbeiten:**

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://api.minimax.io/anthropic",
    "ANTHROPIC_AUTH_TOKEN": "<DEIN_MINIMAX_API_KEY>",
    "API_TIMEOUT_MS": "3000000",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    "ANTHROPIC_MODEL": "MiniMax-M3",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "MiniMax-M3",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "MiniMax-M3",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "MiniMax-M3",
    "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "512000"
  }
}
```

- Base URL international: `https://api.minimax.io/anthropic`; in China: `https://api.minimaxi.com/anthropic`.
- `CLAUDE_CODE_AUTO_COMPACT_WINDOW: 512000` passt zum Kontextfenster von M3.
- Hinweis: Bei einem nicht-Anthropic-Base-URL ist die MCP-Tool-Suche standardmäßig aus.
  Falls gebraucht, zusätzlich `ENABLE_TOOL_SEARCH=true` setzen.

**e) Starten:** ins Projektverzeichnis wechseln, `claude` ausführen, „Trust This Folder"
bestätigen. Mit `/status` bzw. `/model` prüfen, dass **MiniMax-M3** aktiv ist und nicht der
Default-Anthropic-Provider. (Umgebungsvariablen im Shell haben Vorrang vor `settings.json`.)