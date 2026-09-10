#!/usr/bin/python3
"""Receive documented Claude statusline quota metadata; no credentials or transcript text."""
import json,sys,pathlib,time,os,subprocess
base=pathlib.Path.home()/'Library/Application Support/AgentIsland'
raw=sys.stdin.read()
try:
    d=json.loads(raw)
    limits=d.get('rate_limits')
    if isinstance(limits,dict):
        clean={k:{field:v for field,v in value.items() if field in ['used_percentage','resets_at']} for k,value in limits.items() if k in ['five_hour','seven_day'] and isinstance(value,dict)}
        if clean:
            base.mkdir(parents=True,exist_ok=True)
            temp=base/('claude-limits.'+str(os.getpid())+'.tmp')
            temp.write_text(json.dumps(dict(rate_limits=clean,updated=time.time())));temp.chmod(0o600);temp.replace(base/'claude-limits.json')
    previous=base/'previous-statusline.json'
    config=json.loads(previous.read_text()) if previous.exists() else None
    if config and config.get('command'):
        subprocess.run(config['command'],shell=True,input=raw,text=True,timeout=4)
except Exception:pass
