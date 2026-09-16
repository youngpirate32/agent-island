#!/usr/bin/python3
"""Local, metadata-only adapters. Does not store prompts or assistant responses."""
import os, sys, json, time, pathlib, datetime, hashlib, sqlite3
HOME = pathlib.Path.home()
STATE = HOME / 'Library/Application Support/AgentIsland/events'

def log_hook(event, status, sid, notification=None):
    try:
        folder=HOME/'Library/Logs/AgentIsland'
        folder.mkdir(parents=True,exist_ok=True,mode=0o700)
        now=datetime.datetime.now(datetime.timezone.utc)
        for old in folder.glob('hooks-*.jsonl'):
            if time.time()-old.stat().st_mtime > 7*86400: old.unlink()
        path=folder/('hooks-'+now.strftime('%Y-%m-%d')+'.jsonl')
        if path.exists() and path.stat().st_size > 2*1024*1024:return
        row=dict(time=now.isoformat(),event='hook',hook=event,status=status,session=sid,notification=notification)
        fd=os.open(path,os.O_WRONLY|os.O_APPEND|os.O_CREAT,0o600)
        try:os.write(fd,(json.dumps(row)+'\n').encode())
        finally:os.close(fd)
    except OSError:pass

def stamp(value):
    try: return datetime.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
    except (ValueError, TypeError, AttributeError): return time.time()

def source_for(d, default):
    hint = str(d.get('entrypoint', '')) + ' ' + str(d.get('originator', ''))
    if any(x in hint.lower() for x in ['desktop', 'claude-ai', 'local-agent']):
        return 'codex-app' if default.startswith('codex') else 'claude-app'
    return default

def quota_windows(provider, data, updated):
    result=[]
    if not isinstance(data,dict): return result
    windows = [('primary',None),('secondary',None)] if provider == 'codex' else [('five_hour',300),('seven_day',10080)]
    for key,minutes in windows:
        w=data.get(key)
        if not isinstance(w,dict): continue
        used=w.get('used_percent') if provider=='codex' else w.get('used_percentage')
        reset=w.get('resets_at')
        duration=w.get('window_minutes') if provider=='codex' else minutes
        if not isinstance(used,(int,float)) or not isinstance(reset,(int,float)):continue
        limit=data.get('limit_id','codex') if provider=='codex' else 'claude'
        label='Неделя' if duration==10080 else '5 часов' if duration==300 else str(duration or '')+' мин'
        result.append(dict(id=provider+':'+limit+':'+key,provider=provider,label=label,groupName=(data.get('limit_name') or ('Codex' if limit=='codex' else limit)) if provider=='codex' else 'Claude',remaining=max(0,min(100,100-used)),resetsAt=reset,updated=updated))
    return result

def metrics(record,d):
    typ=d.get('type');p=d.get('payload') or {};t=stamp(d.get('timestamp'))
    if typ=='session_meta': record.setdefault('sessionStarted',t)
    if typ=='event_msg' and p.get('type')=='task_started':
        record['turnStarted']=t;record['ended']=None
    if record['source'].startswith('claude'):
        message=d.get('message') or {};content=message.get('content')
        if typ=='user' and not d.get('isMeta') and not d.get('isSidechain'):
            tool_result=isinstance(content,list) and any(isinstance(c,dict) and c.get('type')=='tool_result' for c in content)
            if not tool_result:
                record.setdefault('sessionStarted',t);record['turnStarted']=t;record['ended']=None
        if typ=='assistant' and isinstance(message.get('usage'),dict) and message.get('id') and not d.get('isSidechain'):
            u=message['usage'];entries=record.setdefault('_usage',{})
            current=dict(input=int(u.get('input_tokens',0) or 0)+int(u.get('cache_creation_input_tokens',0) or 0)+int(u.get('cache_read_input_tokens',0) or 0),output=int(u.get('output_tokens',0) or 0),cached=int(u.get('cache_read_input_tokens',0) or 0))
            old=entries.get(message['id'],{})
            entries[message['id']]={k:max(v,old.get(k,0)) for k,v in current.items()}
            record['inputTokens']=sum(v['input'] for v in entries.values())
            record['outputTokens']=sum(v['output'] for v in entries.values())
            record['cachedTokens']=sum(v['cached'] for v in entries.values())
            record['totalTokens']=record['inputTokens']+record['outputTokens']
    if typ=='token_usage_record': u=p.get('thread_token_usage')
    elif typ=='event_msg' and p.get('type')=='token_count': u=(p.get('info') or {}).get('total_token_usage')
    else:u=None
    if isinstance(u,dict):
        record['inputTokens']=int(u.get('input_tokens',0) or 0)
        record['outputTokens']=int(u.get('output_tokens',0) or 0)
        record['cachedTokens']=int(u.get('cached_input_tokens',0) or 0)
        record['totalTokens']=int(u.get('total_tokens',record['inputTokens']+record['outputTokens']) or 0)
    if typ=='event_msg' and p.get('type')=='token_count' and p.get('rate_limits'):
        record['_limits']=quota_windows('codex',p['rate_limits'],t)

def session_details(record,d):
    if d.get('type') in ['ai-title','custom-title']:
        title=d.get('customTitle') or d.get('aiTitle') or d.get('title')
        if isinstance(title,str) and title.strip():record['title']=' '.join(title.split())[:180]

def apply(record, d):
    typ = d.get('type'); p = d.get('payload') or {}
    if typ == 'session_meta':
        record['source'] = source_for(p, 'codex-cli')
        record['id'] = p.get('id', record['id'])
        record['project'] = pathlib.Path(p.get('cwd', '')).name or 'Сеанс Codex'
    record['source'] = source_for(d, record['source'])
    if d.get('cwd'): record['project'] = pathlib.Path(d['cwd']).name
    if d.get('sessionId'): record['id'] = d['sessionId']
    metrics(record,d)
    event = p.get('type') if typ == 'event_msg' else None
    status = None
    if event == 'task_started': status = 'working'
    elif event == 'task_complete': status = 'done'
    elif event in ['turn_aborted', 'task_interrupted']: status = 'idle'
    elif event in ['request_user_input', 'approval_request']: status = 'waiting'
    attention = 'permission' if event == 'approval_request' else 'input'
    if record['source'].startswith('codex'):
        if event == 'user_message': status = 'working'
        if typ == 'response_item':
            kind = p.get('type')
            name = str(p.get('name', ''))
            if kind in ['function_call', 'custom_tool_call']:
                if 'request_user_input' in name and not name.endswith('_async'):
                    status = 'waiting'
                    record['_waiting_call'] = p.get('call_id')
                elif record.get('attention') == 'permission':
                    status = 'working'
            elif kind in ['function_call_output', 'custom_tool_call_output']:
                if p.get('call_id') and p.get('call_id') == record.get('_waiting_call'):
                    status = 'working'
                    record.pop('_waiting_call', None)
    if record['source'].startswith('claude'):
        if d.get('isSidechain'): return
        if typ == 'user': status = 'working'
        elif typ == 'assistant':
            reason = d.get('message', {}).get('stop_reason')
            status = 'done' if reason in ['end_turn', 'stop_sequence'] else 'working'
            content = d.get('message', {}).get('content')
            if isinstance(content, list) and any(isinstance(c, dict) and c.get('type') == 'tool_use' and c.get('name') == 'AskUserQuestion' for c in content):
                status = 'waiting'
        elif typ == 'system' and d.get('subtype') == 'turn_duration': status = 'done'
    if not status and record['status'] == 'working' and typ in ['response_item', 'event_msg']:
        record['updated'] = stamp(d.get('timestamp'))
    if status:
        if status in ['done','idle','error']: record['ended']=stamp(d.get('timestamp'))
        record['attention'] = attention if status == 'waiting' else None
        record['status'] = status
        record['updated'] = stamp(d.get('timestamp'))
    session_details(record,d)

def hook():
    try:
        d = json.load(sys.stdin)
        name = d.get('hook_event_name', '')
        status = {'UserPromptSubmit':'working','PreToolUse':'working','PostToolUse':'working','PostToolUseFailure':'error',
                  'PermissionRequest':'waiting','Stop':'done','StopFailure':'error','SessionEnd':'idle',
                  'Interrupt':'idle'}.get(name)
        if name == 'Notification' and d.get('notification_type') in ['permission_prompt','elicitation_dialog']:
            status = 'waiting'
        if name == 'PreToolUse' and (('request_user_input' in str(d.get('tool_name', '')) and not str(d.get('tool_name', '')).endswith('_async')) or d.get('tool_name') == 'AskUserQuestion'):
            status = 'waiting'
        log_hook(name,status,d.get('session_id','unknown'),d.get('notification_type'))
        if status:
            sid = d.get('session_id', 'unknown')
            obj = dict(id=sid, source=sys.argv[2], status=status, updated=time.time(),
                       project=pathlib.Path(d.get('cwd','')).name or 'Сеанс')
            if name == 'UserPromptSubmit':obj['turnStarted']=obj['updated'];obj['ended']=None
            if status in ['done','idle','error']:obj['ended']=obj['updated']
            obj['attention'] = ('permission' if name == 'PermissionRequest' or d.get('notification_type') == 'permission_prompt' else 'input') if status == 'waiting' else None
            STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
            target = STATE / (hashlib.sha256((sys.argv[2]+sid).encode()).hexdigest()+'.json')
            temp = target.with_suffix('.'+str(os.getpid())+'.tmp')
            temp.write_text(json.dumps(obj)); os.chmod(temp, 0o600); temp.replace(target)
    except Exception: pass
    print('{}')

class Monitor:
    def __init__(self): self.cache = {}; self.paths = []; self.discovered = 0; self.limits=[]; self.titles={}; self.titles_updated=0
    def discover(self):
        roots = [(HOME/'.codex/sessions','codex-cli'), (HOME/'.claude/projects','claude-cli'),
                 (HOME/'Library/Application Support/Claude/local-agent-mode-sessions','claude-app')]
        paths=[]; cutoff=time.time()-86400*3
        for root,source in roots:
            if not root.exists(): continue
            for folder, dirs, files in os.walk(root):
                dirs[:] = [d for d in dirs if d not in ['node_modules','.git','subagents','tool-results','audit']]
                for name in files:
                    if not name.endswith('.jsonl') or name == 'audit.jsonl': continue
                    p=pathlib.Path(folder)/name
                    try:
                        if p.stat().st_mtime > cutoff: paths.append((p,source))
                    except OSError: pass
        self.paths=paths; self.discovered=time.time()
    def load_titles(self):
        if time.time()-self.titles_updated < 10:return
        self.titles_updated=time.time()
        titles={}
        for database in (HOME/'.codex').glob('state_*.sqlite'):
            try:
                connection=sqlite3.connect('file:'+str(database)+'?mode=ro',uri=True,timeout=0.2)
                try:
                    columns={row[1] for row in connection.execute('PRAGMA table_info(threads)')}
                    field="COALESCE(NULLIF(name,''),title)" if 'name' in columns else 'title'
                    for sid,title in connection.execute("SELECT id,"+field+" FROM threads WHERE archived=0"):
                        if isinstance(title,str) and title.strip():titles[sid]=' '.join(title.split())[:180]
                finally:connection.close()
            except sqlite3.Error:pass
        try:
            for line in (HOME/'.codex/session_index.jsonl').read_text().splitlines():
                try:
                    entry=json.loads(line)
                    if entry.get('id') not in titles and isinstance(entry.get('thread_name'),str):titles[entry['id']]=' '.join(entry['thread_name'].split())[:180]
                except (ValueError,KeyError):pass
        except OSError:pass
        self.titles=titles
    def scan(self):
        if time.time()-self.discovered > 15: self.discover()
        self.load_titles()
        records={};limits={}
        for p,source in self.paths:
            try:
                size=p.stat().st_size
                offset,r=self.cache.get(str(p),(0,dict(id=p.stem,source=source,status='unknown',updated=0,project='Сеанс')))
                if size < offset: offset=0;r=dict(id=p.stem,source=source,status='unknown',updated=0,project='Сеанс')
                with p.open('rb') as f:
                    f.seek(offset)
                    for _ in range(100000):
                        line=f.readline()
                        if not line or not line.endswith(b'\n'): break
                        offset=f.tell()
                        try: apply(r,json.loads(line))
                        except (ValueError,TypeError,AttributeError): pass
                if source == 'claude-app':
                    local_id = next((part for part in p.parts if part.startswith('local_')), None)
                    if local_id: r['desktopSessionID'] = local_id
                self.cache[str(p)]=(offset,r)
                for limit in r.get('_limits',[]):
                    if limit['updated'] > limits.get(limit['id'],{}).get('updated',0):limits[limit['id']]=limit
                if r['updated'] > time.time()-86400: records[r['id']]={k:v for k,v in r.items() if not k.startswith('_')}
            except OSError: pass
        if STATE.exists():
            for p in STATE.glob('*.json'):
                try:
                    r=json.loads(p.read_text()); old=records.get(r['id'])
                    if r['updated'] < time.time()-86400: continue
                    if old and old['source'].endswith('-app'): r['source']=old['source']
                    if not old or old['updated'] < r['updated']: records[r['id']]=dict(old or {},**{k:v for k,v in r.items() if not k.startswith('_')})
                except (OSError,ValueError,KeyError): pass
        quota_file=STATE.parent/'claude-limits.json'
        try:
            data=json.loads(quota_file.read_text())
            for limit in quota_windows('claude',data.get('rate_limits'),data.get('updated',0)):limits[limit['id']]=limit
        except (OSError,ValueError,TypeError):pass
        self.limits=sorted(limits.values(),key=lambda x:(x['provider'],x['label']))
        for r in records.values():
            if r['source'].startswith('codex') and r['id'] in self.titles:r['title']=self.titles[r['id']]
            if r['status']=='working' and time.time()-r['updated']>600: r['status']='unknown'
        return sorted(records.values(),key=lambda r:r['updated'],reverse=True)[:30]

if __name__=='__main__':
    if '--hook' in sys.argv: hook()
    else:
        m=Monitor()
        while True:
            try:
                sessions=m.scan()
                print(json.dumps(dict(sessions=sessions,limits=m.limits),ensure_ascii=False),flush=True)
            except BrokenPipeError: break
            if '--once' in sys.argv: break
            time.sleep(3)
