"""Minimal Kafka probe for ACL tests that need client features rpk lacks.

    probe.py produce --user U --password P --topic T [--idempotent] [--txn-id ID]
    probe.py consume --user U --password P --topic T --group G

Prints one JSON line: {"ok": bool, "error": str|null}. Exit code 0 iff ok.
"""
import argparse
import json
import sys

from confluent_kafka import Consumer, KafkaException, Producer

BOOTSTRAP = "redpanda:9092"


def base(args):
    return {
        "bootstrap.servers": BOOTSTRAP,
        "security.protocol": "SASL_PLAINTEXT",
        "sasl.mechanism": "SCRAM-SHA-256",
        "sasl.username": args.user,
        "sasl.password": args.password,
    }


def produce(args):
    conf = base(args) | {"enable.idempotence": args.idempotent, "acks": "all", "message.timeout.ms": 10000}
    if args.txn_id:
        conf["transactional.id"] = args.txn_id
    p = Producer(conf)
    errors = []
    if args.txn_id:
        p.init_transactions(10)
        p.begin_transaction()
    p.produce(args.topic, b'{"probe":true}', on_delivery=lambda e, m: e and errors.append(e))
    if args.txn_id:
        p.commit_transaction(10)
    p.flush(15)
    if errors:
        raise KafkaException(errors[0])


def consume(args):
    c = Consumer(base(args) | {"group.id": args.group, "auto.offset.reset": "earliest", "enable.auto.commit": False})
    c.subscribe([args.topic])
    try:
        for _ in range(20):
            m = c.poll(1.0)
            if m is None:
                continue
            if m.error():
                raise KafkaException(m.error())
            c.commit(m, asynchronous=False)
            return
        raise RuntimeError("no message received")
    finally:
        c.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["produce", "consume"])
    ap.add_argument("--user", required=True)
    ap.add_argument("--password", required=True)
    ap.add_argument("--topic", required=True)
    ap.add_argument("--group")
    ap.add_argument("--idempotent", action="store_true")
    ap.add_argument("--txn-id")
    args = ap.parse_args()
    try:
        (produce if args.mode == "produce" else consume)(args)
        print(json.dumps({"ok": True, "error": None}))
    except Exception as e:  # report any client error as a probe failure
        print(json.dumps({"ok": False, "error": str(e)}))
        sys.exit(1)


if __name__ == "__main__":
    main()
