#!/usr/bin/env bash
set -u  # unbenutzte Variablen verhindern

# ==============================
# Einstellungen
# ==============================

EMAIL_TO="alexgreub@outlook.de"       # Empfänger
EMAIL_FROM="alexgreub@outlook.de"     # Absender (Header + Envelope)
REPORT_FILE="/var/log/lynis-report.dat"
LYNIS_LOG="/var/log/lynis.log"
LOG_FILE="/var/log/lynis-weekly-mail.log"

# Hostname fix
HOSTNAME="web01"
DATE_NOW="$(date '+%Y-%m-%d %H:%M:%S')"
MAIL_SUBJECT="NETSY Security Audit - ${HOSTNAME}"

# ==============================
# Logging
# ==============================

# Wenn alles läuft, kannst du das einkommentieren, damit alles ins Log geht:
# exec >>"$LOG_FILE" 2>&1

echo "========== $(date '+%Y-%m-%d %H:%M:%S') =========="
echo "Starte NETSY Security Audit Script"
echo "Host: $HOSTNAME"

# ==============================
# Lynis finden
# ==============================

LYNIS_BIN="$(command -v lynis || true)"

if [[ -z "$LYNIS_BIN" ]]; then
    echo "FEHLER: lynis wurde nicht im PATH gefunden. Bitte Lynis installieren oder PATH prüfen."
    exit 1
fi

echo "Verwende Lynis-Binary: $LYNIS_BIN"

# sendmail vorhanden?
if ! command -v sendmail >/dev/null 2>&1; then
    echo "FEHLER: sendmail nicht gefunden. Bitte MTA installieren/konfigurieren."
    exit 1
fi

# ==============================
# Lynis FULL Audit ausführen
# ==============================

OUTPUT_TMP="$(mktemp /tmp/lynis-output.XXXXXX)"

echo "Führe Lynis FULL Audit aus..."
# absichtlich OHNE --cronjob, damit der komplette Text inkl. Results geschrieben wird
"$LYNIS_BIN" audit system > "$OUTPUT_TMP" 2>&1
RET_LYNIS=$?
echo "Lynis Exit-Code: $RET_LYNIS"

if [[ ! -f "$REPORT_FILE" ]]; then
    echo "FEHLER: Lynis-Report-Datei $REPORT_FILE nicht gefunden."
    rm -f "$OUTPUT_TMP"
    exit 1
fi

if [[ ! -f "$LYNIS_LOG" ]]; then
    echo "FEHLER: Lynis-Logdatei $LYNIS_LOG nicht gefunden."
    rm -f "$OUTPUT_TMP"
    exit 1
fi

# ==============================
# Zusammenfassung aus report.dat
# ==============================

HARDENING_INDEX="$(grep '^hardening_index=' "$REPORT_FILE" | cut -d= -f2)"

WARNINGS_RAW="$(grep '^warning\[' "$REPORT_FILE" | sed 's/^warning\[[0-9]*\]=//')"
SUGGESTIONS_RAW="$(grep '^suggestion\[' "$REPORT_FILE" | sed 's/^suggestion\[[0-9]*\]=//')"

WARNINGS_COUNT="$(printf '%s\n' "$WARNINGS_RAW" | sed '/^$/d' | wc -l | tr -d ' ')"
SUGGESTIONS_COUNT="$(printf '%s\n' "$SUGGESTIONS_RAW" | sed '/^$/d' | wc -l | tr -d ' ')"

# ==============================
# „Lynis Results“-Block aus lynis.log (immer der letzte)
# ==============================

RESULTS_TEXT="$(
  awk '
    /-\[ Lynis .* Results \]-/ { capture=1; buf=$0 ORS; next }
    capture { buf = buf $0 ORS }
    END { print buf }
  ' "$LYNIS_LOG"
)"

if [[ -z "$RESULTS_TEXT" ]]; then
    RESULTS_TEXT="Lynis Results section not found in log file ${LYNIS_LOG}."
fi

# Tests performed aus Results-Block ziehen
TESTS_PERFORMED="$(
  printf '%s\n' "$RESULTS_TEXT" \
  | awk -F':' '/Tests performed/{gsub(/^[ \t]+/,"",$2); print $2; exit}' \
  | xargs
)"

if [[ -z "$TESTS_PERFORMED" ]]; then
    TESTS_PERFORMED="n/a"
fi

# ==============================
# HTML-Escaping Helfer
# ==============================

html_escape() {
    sed -e 's/&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g'
}

RESULTS_ESCAPED="$(printf '%s\n' "$RESULTS_TEXT" | html_escape)"

# ==============================
# HTML-Mail-Body bauen
# ==============================

MAIL_TMP="$(mktemp /tmp/lynis-mail.XXXXXX)"
echo "Schreibe HTML-Mail-Body nach $MAIL_TMP"

cat > "$MAIL_TMP" <<EOF
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="UTF-8">
<title>${MAIL_SUBJECT}</title>
<style>
    body {
        font-family: Arial, sans-serif;
        background-color: #f5f7fa;
        color: #333333;
        margin: 0;
        padding: 0;
    }
    .container {
        max-width: 900px;
        margin: 20px auto;
        background-color: #ffffff;
        border-radius: 8px;
        padding: 20px 30px;
        box-shadow: 0 2px 6px rgba(0,0,0,0.08);
    }
    h1, h2, h3 {
        color: #1a3b5d;
        margin-top: 0;
    }
    .header {
        border-bottom: 1px solid #e0e6ed;
        padding-bottom: 10px;
        margin-bottom: 20px;
    }
    .meta-table {
        width: 100%;
        border-collapse: collapse;
        margin-bottom: 20px;
    }
    .meta-table th, .meta-table td {
        text-align: left;
        padding: 6px 8px;
    }
    .meta-table th {
        background-color: #f0f4f8;
        width: 220px;
    }
    .summary-boxes {
        display: flex;
        flex-wrap: wrap;
        gap: 10px;
        margin-bottom: 25px;
    }
    .summary-box {
        flex: 1 1 180px;
        background-color: #f8fafc;
        border-radius: 6px;
        padding: 10px 12px;
        border: 1px solid #e0e6ed;
    }
    .summary-title {
        font-size: 11px;
        text-transform: uppercase;
        color: #66758c;
        margin-bottom: 4px;
        letter-spacing: 0.04em;
    }
    .summary-value {
        font-size: 20px;
        font-weight: bold;
        color: #1a3b5d;
    }
    .section {
        margin-bottom: 25px;
    }
    .pre-block {
        background-color: #0b1020;
        color: #e0e6ff;
        padding: 15px;
        border-radius: 6px;
        font-family: "Courier New", monospace;
        font-size: 12px;
        white-space: pre-wrap;
        word-wrap: break-word;
        overflow-x: auto;
    }
    .footer {
        margin-top: 20px;
        font-size: 11px;
        color: #8892a0;
        border-top: 1px solid #e0e6ed;
        padding-top: 10px;
    }
</style>
</head>
<body>
<div class="container">
    <div class="header">
        <h1>NETSY Security Audit</h1>
        <p>Automatischer Lynis-Report (regelmässiger System-Audit)</p>
    </div>

    <div class="section">
        <h2>Metadaten</h2>
        <table class="meta-table">
            <tr>
                <th>Host</th>
                <td>${HOSTNAME}</td>
            </tr>
            <tr>
                <th>Datum</th>
                <td>${DATE_NOW}</td>
            </tr>
            <tr>
                <th>Lynis Exit-Code</th>
                <td>${RET_LYNIS}</td>
            </tr>
            <tr>
                <th>Report-Datei</th>
                <td>${REPORT_FILE}</td>
            </tr>
        </table>
    </div>

    <div class="section">
        <h2>Zusammenfassung</h2>
        <div class="summary-boxes">
            <div class="summary-box">
                <div class="summary-title">Hardening-Index</div>
                <div class="summary-value">${HARDENING_INDEX}</div>
            </div>
            <div class="summary-box">
                <div class="summary-title">Tests durchgeführt</div>
                <div class="summary-value">${TESTS_PERFORMED}</div>
            </div>
            <div class="summary-box">
                <div class="summary-title">Warnings</div>
                <div class="summary-value">${WARNINGS_COUNT}</div>
            </div>
            <div class="summary-box">
                <div class="summary-title">Suggestions</div>
                <div class="summary-value">${SUGGESTIONS_COUNT}</div>
            </div>
        </div>
    </div>

    <div class="section">
        <h2>Lynis Ergebnisdetails</h2>
        <p>Nachfolgend der originale <em>Lynis Results</em>-Block mit Warnings, Suggestions und Detailhinweisen:</p>
        <div class="pre-block">
${RESULTS_ESCAPED}
        </div>
    </div>

    <div class="footer">
        <p>Diese E-Mail wurde automatisch durch das NETSY Security Audit Script generiert.</p>
    </div>
</div>
</body>
</html>
EOF

# ==============================
# Mail versenden (HTML)
# ==============================

echo "Versende HTML-Mail über sendmail mit Envelope-From: $EMAIL_FROM"

/usr/sbin/sendmail -t -f "$EMAIL_FROM" <<EOF
From: $EMAIL_FROM
To: $EMAIL_TO
Subject: $MAIL_SUBJECT
MIME-Version: 1.0
Content-Type: text/html; charset="UTF-8"
Content-Transfer-Encoding: 8bit

$(cat "$MAIL_TMP")
EOF

RET_MAIL=$?
echo "sendmail Exit-Code: $RET_MAIL"

rm -f "$MAIL_TMP" "$OUTPUT_TMP"
echo "Script beendet mit Status: $RET_MAIL"
exit "$RET_MAIL"
