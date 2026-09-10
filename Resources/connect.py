import json,pathlib,shutil,datetime,shlex,sys
home=pathlib.Path.home()
base=home/'Library/Application Support/AgentIsland'
base.mkdir(parents=True,exist_ok=True)
script=base/'monitor.py'
shutil.copy2(pathlib.Path(__file__).with_name('monitor.py'),script)
backup=base/'backups'/datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
backup.mkdir(parents=True,exist_ok=True)
for file,source,events in [
    (home/'.claude/settings.json','claude-cli',['UserPromptSubmit','PreToolUse','PostToolUse','PermissionRequest','Notification','Stop','StopFailure','SessionEnd']),
    (home/'.codex/hooks.json','codex-cli',['UserPromptSubmit','PreToolUse','PostToolUse','PermissionRequest','Stop','Interrupt','SessionEnd'])]:
    config=json.loads(file.read_text()) if file.exists() else {}
    if file.exists(): shutil.copy2(file,backup/(source+'.json'))
    hooks=config.setdefault('hooks',{})
    for event in events:
        groups=hooks.setdefault(event,[])
        command='/usr/bin/python3 '+shlex.quote(str(script))+' --hook '+source
        if any(any(h.get('command')==command for h in g.get('hooks',[])) for g in groups): continue
        groups.append({'hooks':[{'type':'command','command':command,'timeout':3}]})
    file.parent.mkdir(parents=True,exist_ok=True)
    temp=file.with_suffix('.agentisland.tmp')
    temp.write_text(json.dumps(config,ensure_ascii=False,indent=2)+'\n')
    temp.chmod(0o600); temp.replace(file)
print('Подключены Codex и Claude Code. Существующие настройки сохранены.')
print('Новые hooks подхватят новые сеансы; для уже открытых может понадобиться перезапуск.')
print('Резервные копии: '+str(backup))
