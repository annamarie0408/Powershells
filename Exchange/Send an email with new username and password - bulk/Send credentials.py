#!/usr/bin/env python3
"""
send_credentials.py

Reads a CSV of users and emails each one their new username and password,
sending from your own email account over SMTP.

Expected CSV columns (header row required, names are case-insensitive):
    email, username, password
Optional column:
    name   (used in the greeting; falls back to the username)

Usage:
    python send_credentials.py users.csv              # dry run (prints, sends nothing)
    python send_credentials.py users.csv --send       # actually sends the emails

Your email password is read from the SMTP_PASSWORD environment variable,
or you'll be prompted for it. It is never stored in this file.
"""

import csv
import os
import smtplib
import sys
import time
import argparse
from getpass import getpass
from email.message import EmailMessage

# ---------------------------------------------------------------------------
# SETTINGS - edit these
# ---------------------------------------------------------------------------
SENDER_EMAIL = "you@example.com"      # your email address
SENDER_NAME = "IT Support"            # name recipients will see

# Common SMTP servers:
#   Gmail:            smtp.gmail.com         port 587
#   Outlook.com:      smtp-mail.outlook.com  port 587
#   Microsoft 365:    smtp.office365.com     port 587
#   Yahoo:            smtp.mail.yahoo.com    port 587
SMTP_SERVER = "smtp.gmail.com"
SMTP_PORT = 587

SUBJECT = "Your new account login details"
LOGIN_URL = "https://example.com/login"   # where users should log in
DELAY_SECONDS = 2                          # pause between emails to avoid rate limits

BODY_TEMPLATE = """Hi {name},

Your account has been set up. Here are your login details:

    Username: {username}
    Temporary password: {password}

Log in here: {login_url}

For your security, please change your password the first time you log in.

Thanks,
{sender_name}
"""
# ---------------------------------------------------------------------------


def load_users(csv_path):
    """Read the CSV and return a list of dicts with normalized lowercase keys."""
    with open(csv_path, newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        if not reader.fieldnames:
            sys.exit("Error: CSV file appears to be empty.")
        fields = [h.strip().lower() for h in reader.fieldnames]
        missing = {"email", "username", "password"} - set(fields)
        if missing:
            sys.exit(f"Error: CSV is missing column(s): {', '.join(sorted(missing))}")

        users = []
        for line_no, row in enumerate(reader, start=2):
            row = {k.strip().lower(): (v or "").strip() for k, v in row.items() if k}
            if not row.get("email") or "@" not in row["email"]:
                print(f"  Skipping line {line_no}: missing or invalid email")
                continue
            users.append(row)
        return users


def build_message(user):
    msg = EmailMessage()
    msg["From"] = f"{SENDER_NAME} <{SENDER_EMAIL}>"
    msg["To"] = user["email"]
    msg["Subject"] = SUBJECT
    msg.set_content(BODY_TEMPLATE.format(
        name=user.get("name") or user["username"],
        username=user["username"],
        password=user["password"],
        login_url=LOGIN_URL,
        sender_name=SENDER_NAME,
    ))
    return msg


def main():
    parser = argparse.ArgumentParser(description="Email new credentials to users in a CSV.")
    parser.add_argument("csv_file", help="Path to the CSV file")
    parser.add_argument("--send", action="store_true",
                        help="Actually send the emails (without this it's a dry run)")
    args = parser.parse_args()

    users = load_users(args.csv_file)
    print(f"Found {len(users)} user(s) in {args.csv_file}")
    if not users:
        return

    if not args.send:
        print("\nDRY RUN - nothing will be sent. Preview of the first email:\n")
        print(build_message(users[0]))
        print("\nRecipients:")
        for u in users:
            print(f"  {u['email']}  (username: {u['username']})")
        print("\nRun again with --send to send for real.")
        return

    password = os.environ.get("SMTP_PASSWORD") or getpass(f"Password for {SENDER_EMAIL}: ")

    sent, failed = 0, []
    with smtplib.SMTP(SMTP_SERVER, SMTP_PORT, timeout=30) as server:
        server.starttls()
        server.login(SENDER_EMAIL, password)
        for i, user in enumerate(users, start=1):
            try:
                server.send_message(build_message(user))
                sent += 1
                print(f"[{i}/{len(users)}] Sent to {user['email']}")
            except Exception as e:
                failed.append((user["email"], str(e)))
                print(f"[{i}/{len(users)}] FAILED {user['email']}: {e}")
            time.sleep(DELAY_SECONDS)

    print(f"\nDone. Sent: {sent}  Failed: {len(failed)}")
    if failed:
        with open("failed_emails.csv", "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(["email", "error"])
            w.writerows(failed)
        print("Failed addresses written to failed_emails.csv")


if __name__ == "__main__":
    main()
