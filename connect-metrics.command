#!/bin/zsh
set -e
cd "${0:A:h}"
/usr/bin/python3 - <<'PY'
import pathlib,json,shutil,datetime,shlex
h=pathlib.Path.home();base=h/'Library/Application Support/AgentIsland';base.mkdir(parents=True,exist_ok=True)
for f in ['monitor.py','statusline.py']:shutil.copy2(pathlib.Path('Resources')/f,base/f)
p=h/'.claude/settings.json';config=json.loads(p.read_text()) if p.exists() else {}
command='/usr/bin/python3 '+shlex.quote(str(base/'statusline.py'))
if (config.get('statusLine') or {}).get('command') != command:
 backup=base/'backups'/datetime.datetime.now().strftime('metrics-%Y%m%d-%H%M%S');backup.mkdir(parents=True,exist_ok=True)
 if p.exists():shutil.copy2(p,backup/'claude-settings.json')
 (base/'previous-statusline.json').write_text(json.dumps(config.get('statusLine')))
 config['statusLine']=dict(type='command',command=command)
 p.parent.mkdir(parents=True,exist_ok=True);temp=p.with_suffix('.agentisland.tmp');temp.write_text(json.dumps(config,ensure_ascii=False,indent=2)+'\n');temp.chmod(0o600);temp.replace(p)
print('Передача лимитов Claude подключена. Данные появятся после ответа в Claude Code, если версия поддерживает rate_limits.')
PY
