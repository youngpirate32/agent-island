#!/bin/zsh
set -e
/usr/bin/python3 - <<'PY'
import pathlib,json,datetime,shutil
h=pathlib.Path.home(); backup=h/'Library/Application Support/AgentIsland/backups'/('disconnect-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'));backup.mkdir(parents=True,exist_ok=True)
for p,name in [(h/'.claude/settings.json','claude'),(h/'.codex/hooks.json','codex')]:
 if not p.exists():continue
 d=json.loads(p.read_text());shutil.copy2(p,backup/(name+'.json'))
 if name=='claude' and '/AgentIsland/statusline.py' in (d.get('statusLine') or {}).get('command',''):
  old=h/'Library/Application Support/AgentIsland/previous-statusline.json'
  previous=json.loads(old.read_text()) if old.exists() else None
  if previous is None:d.pop('statusLine',None)
  else:d['statusLine']=previous
 for event,groups in list(d.get('hooks',{}).items()):
  kept=[]
  for g in groups:
   original=g.get('hooks',[])
   filtered=[x for x in original if '/AgentIsland/monitor.py' not in x.get('command','')]
   if filtered or not original:kept.append(dict(g,hooks=filtered))
  d['hooks'][event]=kept
 temp=p.with_suffix('.agentisland.tmp');temp.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n');temp.chmod(0o600);temp.replace(p)
print('События Agent Island отключены. Другие подключения сохранены. Выйдите из приложения через значок в строке меню.')
PY
