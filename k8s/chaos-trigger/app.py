"""Chaos Trigger API — lightweight Flask app to trigger/status/cleanup chaos scenarios."""
import subprocess, json, os, time
from flask import Flask, jsonify, request
from flask_cors import CORS

app = Flask(__name__)
CORS(app)

SCENARIOS = {
    "redis-failure": {
        "name": "Redis 级联故障",
        "cronjob": "chaos-redis-failure",
        "description": "阻断 Redis 连接 + 注入无效 REDIS_URL → CrashLoopBackOff",
        "duration": "~12 min",
        "alert": "OutlinePodCrashLooping",
    },
    "dns-failure": {
        "name": "DNS 解析故障",
        "cronjob": "chaos-dns-failure",
        "description": "注入不可达 DNS 服务器 → 所有域名解析失败 → CrashLoopBackOff",
        "duration": "~10 min",
        "alert": "OutlineDNSFailure",
    },
    "oom-kill": {
        "name": "OOM Kill（内存不足）",
        "cronjob": "chaos-oom-kill",
        "description": "内存限制从 1Gi 降到 200Mi → OOM Kill (exit 137) → CrashLoopBackOff",
        "duration": "~10 min",
        "alert": "OutlinePodOOMKilled",
    },
    "db-exhaust": {
        "name": "DB 连接失败",
        "cronjob": "chaos-db-exhaust",
        "description": "注入无效 DATABASE_URL → 数据库连接超时 → CrashLoopBackOff",
        "duration": "~10 min",
        "alert": "OutlineDBConnectionFailure",
    },
}

NS = "outline"

def _kubectl(*args):
    r = subprocess.run(["kubectl", "-n", NS] + list(args),
                       capture_output=True, text=True, timeout=30)
    return r.stdout.strip(), r.stderr.strip(), r.returncode

@app.route("/")
def index():
    return jsonify({"scenarios": SCENARIOS, "endpoints": {
        "trigger": "POST /trigger/<scenario>",
        "status": "GET /status",
        "cleanup": "POST /cleanup/<scenario>",
    }})

@app.route("/trigger/<scenario>", methods=["POST"])
def trigger(scenario):
    if scenario not in SCENARIOS:
        return jsonify({"error": f"Unknown scenario: {scenario}"}), 404
    info = SCENARIOS[scenario]
    job_name = f"demo-{scenario}-{int(time.time())}"
    out, err, rc = _kubectl("create", "job", f"--from=cronjob/{info['cronjob']}", job_name)
    if rc != 0:
        return jsonify({"error": err}), 500
    return jsonify({"status": "triggered", "scenario": scenario, "job": job_name,
                     "message": f"{info['name']} 已触发，预计 {info['duration']} 完成"})

@app.route("/status")
def status():
    # Active chaos jobs
    out, _, _ = _kubectl("get", "jobs", "-l", "app=chaos", "-o", "json")
    jobs = []
    if out:
        for j in json.loads(out).get("items", []):
            jobs.append({
                "name": j["metadata"]["name"],
                "status": "Complete" if j["status"].get("succeeded") else
                          "Failed" if j["status"].get("failed") else "Running",
                "age": j["metadata"].get("creationTimestamp", ""),
            })
    # Pod health
    out2, _, _ = _kubectl("get", "pods", "-l", "app=outline,component=web",
                          "-o", "jsonpath={range .items[*]}{.metadata.name}|{.status.phase}|{.status.containerStatuses[0].restartCount}\\n{end}")
    pods = []
    for line in out2.strip().split("\n"):
        if "|" in line:
            parts = line.split("|")
            pods.append({"pod": parts[0], "phase": parts[1], "restarts": parts[2]})
    # NetworkPolicies
    out3, _, _ = _kubectl("get", "networkpolicy", "-l", "app=chaos", "-o",
                          "jsonpath={range .items[*]}{.metadata.name} {end}")
    return jsonify({"jobs": jobs, "pods": pods,
                     "active_network_policies": out3.split() if out3 else []})

@app.route("/cleanup/<scenario>", methods=["POST"])
def cleanup(scenario):
    results = []
    # Delete chaos jobs for this scenario
    out, _, _ = _kubectl("delete", "jobs", "-l", f"scenario={scenario}", "--ignore-not-found")
    results.append(out)
    # Delete network policies
    for np in ["block-redis", "block-dns", "block-postgres"]:
        out, _, _ = _kubectl("delete", "networkpolicy", np, "--ignore-not-found")
        if "deleted" in out:
            results.append(out)
    # Rollback deployment
    out, _, _ = _kubectl("rollout", "undo", "deployment/outline-web")
    results.append(out)
    return jsonify({"status": "cleanup done", "actions": results})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
