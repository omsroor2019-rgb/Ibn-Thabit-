#!/usr/bin/env python3
"""Run app SQLite DDL and financial invariants using system SQLite.

This is a fast schema/invariant smoke test. It does not replace Flutter tests,
SQLCipher native integration tests, or Android device testing.
"""
from __future__ import annotations

import ast
from pathlib import Path
import re
import sqlite3

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "lib" / "data" / "app_database.dart"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    source = SOURCE.read_text(encoding="utf-8")
    start = source.index("onCreate: (db, version) async {")
    end = source.index("\n      },", start)
    on_create = source[start:end]
    pattern = r"await db\.execute\(\s*('''.*?'''|'(?:\\.|[^'])*')\s*\);"
    literals = re.findall(pattern, on_create, re.S)
    statements = [
        literal[3:-3] if literal.startswith("'''") else ast.literal_eval(literal)
        for literal in literals
    ]
    require(len(statements) >= 11, f"Expected table/index/trigger DDL; found {len(statements)} statements")

    connection = sqlite3.connect(":memory:")
    connection.execute("PRAGMA foreign_keys = ON")
    for index, statement in enumerate(statements, start=1):
        try:
            connection.executescript(statement)
        except sqlite3.Error as error:
            raise AssertionError(f"DDL statement {index} failed: {error}\n{statement}") from error

    connection.executemany(
        "INSERT INTO app_meta(key, value) VALUES (?, ?)",
        [("next_customer_no", "100001"), ("next_supplier_no", "200001")],
    )
    timestamp = "2026-11-27T00:00:00.000Z"

    def create_party(account_no: int, kind: str, name: str) -> int:
        cursor = connection.execute(
            "INSERT INTO parties(account_no,kind,name,created_at) VALUES (?,?,?,?)",
            (account_no, kind, name, timestamp),
        )
        return int(cursor.lastrowid)

    customer_id = create_party(100001, "customer", "عميل اختبار")
    supplier_id = create_party(200001, "supplier", "مورد اختبار")
    for account_no, kind in [
        (200001, "customer"),
        (100001, "supplier"),
        (200000, "customer"),
        (200000, "supplier"),
    ]:
        try:
            create_party(account_no, kind, "حساب غير صالح")
        except sqlite3.IntegrityError:
            pass
        else:
            raise AssertionError(f"Invalid account number {account_no} / {kind} was accepted")

    def transaction(party_id: int, kind: str, amount: int, currency: str = "SAR") -> int:
        cursor = connection.execute(
            """INSERT INTO transactions
               (party_id,type,amount_minor,currency,occurred_at,created_at)
               VALUES (?,?,?,?,?,?)""",
            (party_id, kind, amount, currency, timestamp, timestamp),
        )
        return int(cursor.lastrowid)

    charge_id = transaction(customer_id, "charge", 50000)
    payment_id = transaction(customer_id, "payment", 20000)

    def must_reject(action, label: str) -> None:
        try:
            action()
        except sqlite3.IntegrityError:
            return
        raise AssertionError(f"Database constraint did not reject: {label}")

    must_reject(lambda: transaction(customer_id, "payment", 40000), "payment exceeding balance")
    must_reject(
        lambda: connection.execute("UPDATE transactions SET amount_minor=60000 WHERE id=?", (payment_id,)),
        "payment update exceeding balance",
    )
    must_reject(
        lambda: connection.execute("UPDATE transactions SET amount_minor=10000 WHERE id=?", (charge_id,)),
        "reducing charge below paid amount",
    )
    must_reject(
        lambda: connection.execute("UPDATE transactions SET deleted_at=? WHERE id=?", (timestamp, charge_id)),
        "soft deletion of debt supporting a payment",
    )
    must_reject(
        lambda: connection.execute("UPDATE transactions SET currency='YER' WHERE id=?", (payment_id,)),
        "moving a payment away from its source currency and making the old balance negative",
    )
    must_reject(
        lambda: connection.execute("UPDATE transactions SET type='expense' WHERE id=?", (charge_id,)),
        "changing a party ledger item into a general expense",
    )

    # Separate currencies are independent and can never net against one another.
    transaction(customer_id, "charge", 100000, "YER")
    transaction(customer_id, "payment", 60000, "YER")
    balances = dict(
        connection.execute(
            """SELECT currency,
                      SUM(CASE WHEN type='charge' THEN amount_minor ELSE -amount_minor END)
               FROM transactions
               WHERE party_id=? AND deleted_at IS NULL
               GROUP BY currency""",
            (customer_id,),
        ).fetchall()
    )
    require(balances == {"SAR": 30000, "YER": 40000}, f"Unexpected independent balances: {balances}")

    # Safe update and soft-delete remain possible when the balance stays nonnegative.
    extra_charge = transaction(customer_id, "charge", 10000)
    connection.execute("UPDATE transactions SET amount_minor=5000 WHERE id=?", (extra_charge,))
    connection.execute("UPDATE transactions SET deleted_at=? WHERE id=?", (timestamp, extra_charge))

    must_reject(
        lambda: transaction(customer_id, "income", 100, "SAR"),
        "posting a general income to a personal ledger",
    )
    must_reject(
        lambda: transaction(customer_id, "charge", 100, "USD"),
        "unsupported currency",
    )

    require(connection.execute("PRAGMA integrity_check").fetchone()[0] == "ok", "SQLite integrity_check failed")
    require(not list(connection.execute("PRAGMA foreign_key_check")), "Foreign key violations found")
    require(connection.execute("SELECT COUNT(*) FROM parties").fetchone()[0] == 2, "Unexpected party count")
    require(supplier_id > 0, "Supplier creation failed")

    print(f"PASS: {len(statements)} database DDL statements (tables, indexes, triggers)")
    print("PASS: customer/supplier account-number ranges and uniqueness")
    print("PASS: overpayment insert/update, charge changes and soft deletion are guarded")
    print("PASS: SAR and YER ledger balances stay separate", balances)
    print("PASS: SQLite integrity_check and foreign_key_check")
    print("NOTE: system SQLite smoke test only; native SQLCipher and Flutter runtime remain to be tested in CI/device")
    connection.close()


if __name__ == "__main__":
    main()
