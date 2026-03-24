#!/usr/bin/env python3
"""active-tasks.py — Unified writer for memory/active-tasks.json

Usage:
  active-tasks.py upsert --id <id> --title <title> [--project <p>] [--priority <P0|P1|P2>] [--context <ctx>] [--next <action>] [--owner <owner>] [--tags <t1,t2>] [--files <f1,f2>]
  active-tasks.py status --id <id> --status <active|blocked|waiting|done|abandoned> [--context <ctx>]
  active-tasks.py blocker --id <id> --blocker <reason>
  active-tasks.py attempt --id <id> --action <what> --result <outcome>
  active-tasks.py remove --id <id>
  active-tasks.py list [--status <status>]
"""

import json
import argparse
import os
from datetime import datetime

TASKS_FILE = os.path.join(
    os.environ.get(
        "AGENT_SWARM_WORKSPACE",
        os.environ.get("OPENCLAW_WORKSPACE", os.path.expanduser("~/.openclaw/workspace")),
    ),
    "memory",
    "active-tasks.json",
)

def load():
    if os.path.exists(TASKS_FILE):
        with open(TASKS_FILE) as f:
            return json.load(f)
    return {"_schema": "active-tasks.v2", "notes": "", "tasks": []}

def save(data):
    with open(TASKS_FILE, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)

def today():
    return datetime.now().strftime("%Y-%m-%d")

def now():
    return datetime.now().strftime("%Y-%m-%d %H:%M")

def find_task(tasks, task_id):
    for i, t in enumerate(tasks):
        if t.get("id") == task_id:
            return i, t
    return -1, None

def cmd_upsert(args):
    data = load()
    idx, task = find_task(data["tasks"], args.id)
    if task:
        # Update existing
        if args.title: task["title"] = args.title
        if args.project: task["project"] = args.project
        if args.priority: task["priority"] = args.priority
        if args.context: task["context"] = args.context
        if args.next: task["next_action"] = args.next
        if args.owner: task["owner"] = args.owner
        if args.tags: task["tags"] = args.tags.split(",")
        if args.files: task["files"] = args.files.split(",")
        task["updated"] = today()
        data["tasks"][idx] = task
        print(f"Updated: {args.id}")
    else:
        # Create new
        task = {
            "id": args.id,
            "title": args.title or "Untitled",
            "project": args.project or "",
            "status": "active",
            "priority": args.priority or "P1",
            "created": today(),
            "updated": today(),
            "context": args.context or "",
            "blocker": "",
            "next_action": args.next or "",
            "owner": args.owner or "agent-swarm",
            "attempts": [],
            "files": args.files.split(",") if args.files else [],
            "tags": args.tags.split(",") if args.tags else []
        }
        data["tasks"].append(task)
        print(f"Created: {args.id}")
    save(data)

def cmd_status(args):
    data = load()
    idx, task = find_task(data["tasks"], args.id)
    if not task:
        print(f"Not found: {args.id}")
        return 1
    task["status"] = args.status
    task["updated"] = today()
    if args.context:
        task["context"] = args.context
    if args.status == "done":
        task["completedAt"] = now()
    data["tasks"][idx] = task
    save(data)
    print(f"Status -> {args.status}: {args.id}")

def cmd_blocker(args):
    data = load()
    idx, task = find_task(data["tasks"], args.id)
    if not task:
        print(f"Not found: {args.id}")
        return 1
    task["status"] = "blocked"
    task["blocker"] = args.blocker
    task["updated"] = today()
    data["tasks"][idx] = task
    save(data)
    print(f"Blocked: {args.id} — {args.blocker}")

def cmd_attempt(args):
    data = load()
    idx, task = find_task(data["tasks"], args.id)
    if not task:
        print(f"Not found: {args.id}")
        return 1
    task["attempts"].append({
        "date": today(),
        "action": args.action,
        "result": args.result
    })
    task["updated"] = today()
    data["tasks"][idx] = task
    save(data)
    print(f"Attempt added: {args.id}")

def cmd_remove(args):
    data = load()
    idx, task = find_task(data["tasks"], args.id)
    if not task:
        print(f"Not found: {args.id}")
        return 1
    data["tasks"].pop(idx)
    save(data)
    print(f"Removed: {args.id}")

def cmd_list(args):
    data = load()
    tasks = data["tasks"]
    if args.status:
        tasks = [t for t in tasks if t.get("status") == args.status]
    if not tasks:
        print("No tasks")
        return
    for t in tasks:
        status = t.get("status", "?")
        priority = t.get("priority", "?")
        title = t.get("title", "?")
        updated = t.get("updated", "?")
        print(f"[{priority}][{status}] {t['id']}: {title} (updated: {updated})")

def main():
    parser = argparse.ArgumentParser(description="active-tasks.json manager")
    sub = parser.add_subparsers(dest="command")

    p_upsert = sub.add_parser("upsert")
    p_upsert.add_argument("--id", required=True)
    p_upsert.add_argument("--title")
    p_upsert.add_argument("--project")
    p_upsert.add_argument("--priority")
    p_upsert.add_argument("--context")
    p_upsert.add_argument("--next")
    p_upsert.add_argument("--owner")
    p_upsert.add_argument("--tags")
    p_upsert.add_argument("--files")

    p_status = sub.add_parser("status")
    p_status.add_argument("--id", required=True)
    p_status.add_argument("--status", required=True)
    p_status.add_argument("--context")

    p_blocker = sub.add_parser("blocker")
    p_blocker.add_argument("--id", required=True)
    p_blocker.add_argument("--blocker", required=True)

    p_attempt = sub.add_parser("attempt")
    p_attempt.add_argument("--id", required=True)
    p_attempt.add_argument("--action", required=True)
    p_attempt.add_argument("--result", required=True)

    p_remove = sub.add_parser("remove")
    p_remove.add_argument("--id", required=True)

    p_list = sub.add_parser("list")
    p_list.add_argument("--status")

    args = parser.parse_args()
    if not args.command:
        parser.print_help()
        return

    {"upsert": cmd_upsert, "status": cmd_status, "blocker": cmd_blocker,
     "attempt": cmd_attempt, "remove": cmd_remove, "list": cmd_list}[args.command](args)

if __name__ == "__main__":
    main()
