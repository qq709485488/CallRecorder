import os
import requests
import urllib3
import json

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

TOKEN = os.environ.get("GH_TOKEN", "")
REPO = "qq709485488/CallRecorder"
HEADERS = {
    "Authorization": f"token {TOKEN}",
    "Accept": "application/vnd.github+json"
}

# Get the latest run
runs_url = f"https://api.github.com/repos/{REPO}/actions/runs?per_page=1"
resp = requests.get(runs_url, headers=HEADERS, verify=False)
runs = resp.json()
latest_run = runs["workflow_runs"][0]
run_id = latest_run["id"]
print(f"Latest run ID: {run_id}")

# Get jobs
jobs_url = f"https://api.github.com/repos/{REPO}/actions/runs/{run_id}/jobs"
jobs_resp = requests.get(jobs_url, headers=HEADERS, verify=False)
jobs = jobs_resp.json()

for job in jobs.get("jobs", []):
    if job["conclusion"] == "failure":
        print(f"Failed job: {job['name']} (ID: {job['id']})")
        for step in job.get("steps", []):
            if step["conclusion"] == "failure":
                print(f"  Failed step: {step['name']}")
        
        # Get logs for this job
        logs_url = f"https://api.github.com/repos/{REPO}/actions/jobs/{job['id']}/logs"
        logs_resp = requests.get(logs_url, headers=HEADERS, verify=False)
        # The logs are returned as raw text, get the last 100 lines
        lines = logs_resp.text.split('\n')
        # Find error lines and last meaningful lines
        error_lines = []
        for i, line in enumerate(lines):
            if 'error:' in line.lower() or 'Error' in line or 'fatal' in line.lower():
                # Get context around error
                start = max(0, i-2)
                end = min(len(lines), i+5)
                for j in range(start, end):
                    if lines[j] not in error_lines:
                        error_lines.append(lines[j])
                error_lines.append('---')
        
        if error_lines:
            print("\nError context:")
            for line in error_lines[-50:]:
                print(line)
        else:
            print("\nLast 50 lines of log:")
            for line in lines[-50:]:
                print(line)