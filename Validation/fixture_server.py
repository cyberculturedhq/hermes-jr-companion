"""Hermes dashboard protocol fixture. Contains no real credentials or model calls."""
import asyncio
import base64
from aiohttp import web

TOKEN = 'fixture-dashboard-token'
profiles = [dict(name='default', path='/fixture/hermes', display_name='Hermes', description='General', model='test-model', gateway_running=False), dict(name='research', path='/fixture/hermes/profiles/research', display_name='Research', description='Research profile', model='research-model', gateway_running=True)]
rpc_requests = []
launch_home = '/fixture/hermes'
bot_mode = 'available'
bot_lookup_delay = 0
bot_message_delay = 0
bot_preview = 'Existing continuous bot conversation'
bot_delivery_mode = 'owner'
bot_replies = {}

async def fixture_bot(request):
    global bot_mode, bot_lookup_delay, bot_message_delay, bot_preview, bot_delivery_mode
    body = await request.json()
    bot_mode = body.get('mode', 'available')
    bot_lookup_delay = body.get('lookup_delay', 0)
    bot_message_delay = body.get('message_delay', 0)
    bot_preview = body.get('preview', 'Existing continuous bot conversation')
    bot_delivery_mode = body.get('delivery_mode', 'owner')
    bot_replies.clear()
    return web.json_response({'ok': True})

async def fixture_stats(request):
    return web.json_response({'requests': rpc_requests})

async def fixture_identity(request):
    global launch_home
    launch_home = (await request.json()).get('home')
    return web.json_response({'ok': True})

@web.middleware
async def auth(request, handler):
    if request.path.endswith('/api/health') or request.path.endswith('/api/ws'):
        return await handler(request)
    if request.headers.get('Authorization') != 'Bearer ' + TOKEN:
        return web.json_response({'error':'unauthenticated'}, status=401)
    return await handler(request)

async def health(request):
    return web.json_response({'ok':True, 'version':'0.21.1-fixture', 'auth_required':True})

async def me(request):
    return web.json_response({'user_id':'fixture-user'})

async def profile_list(request):
    return web.json_response({'profiles':profiles})

async def sessions(request):
    if request.query.get('profile') != 'research':
        return web.json_response({'error':'wrong profile'},status=400)
    offset=int(request.query.get('offset','0'))
    rows=[dict(id=f'saved-{n}', title=f'Session {n}', preview='Stored on Hermes', last_active=1800000000-n, message_count=2, source='cli') for n in range(offset,min(offset+100,101))]
    return web.json_response({'sessions':rows,'total':101})

async def messages(request):
    sid=request.match_info['sid']
    if request.query.get('profile') != 'research' or sid not in ('saved-0', 'saved-short', 'saved-exact', 'saved-sparse', 'saved-trailing', 'bot-tip', 'bot-next-tip'):
        return web.json_response({'error':'wrong stored identity'}, status=400)
    offset=int(request.query.get('offset','0'))
    limit=int(request.query.get('limit','500'))
    newest=request.query.get('order')=='latest'
    if sid in ('bot-tip', 'bot-next-tip'):
        await asyncio.sleep(bot_message_delay)
        rows = [dict(id='bot-message', role='assistant', content=bot_preview)]
        for rid, reply in bot_replies.items():
            if reply['status'] == 'settled' and reply['session_id'] == sid:
                rows += [dict(id=rid+'-user', role='user', content=reply['text']),
                         dict(id=rid+'-assistant', role='assistant', content=reply['reply'])]
    elif sid=='saved-short':
        indices=list(range(11,-1,-1) if newest else range(12))[offset:offset+limit]
        rows=[dict(id=n,role='user' if n==0 else 'assistant' if n==11 else 'tool',content=f'Message {n}') for n in sorted(indices)]
    elif sid=='saved-sparse':
        indices=list(range(1201,-1,-1) if newest else range(1202))[offset:offset+limit]
        rows=[dict(id=n,role='user' if n==0 else 'assistant' if n==1 else 'tool',content=f'Message {n}') for n in sorted(indices)]
    elif sid=='saved-trailing':
        indices=list(range(41,-1,-1) if newest else range(42))[offset:offset+limit]
        rows=[dict(id=n,role='user' if n==40 else 'assistant' if n==41 else 'tool',content=f'Message {n}') for n in sorted(indices)]
    elif sid=='saved-exact':
        indices=list(range(9,-1,-1) if newest else range(10))[offset:offset+limit]
        rows=[dict(id=n,role='user' if n%2==0 else 'assistant',content=f'Message {n}') for n in sorted(indices)]
    else:
        indices=list(range(500,-1,-1) if newest else range(501))[offset:offset+limit]
        rows=[dict(id=n,role='user' if n%2==0 else 'assistant',content=f'Message {n}') for n in sorted(indices)]
    return web.json_response({'messages':rows,'pagination':{'returned':len(rows)}})

async def ticket(request):
    return web.json_response({'ticket':'one-time-fixture-ticket'})

uploaded_files = {}
async def upload_capabilities(request):
    result = {'file_upload': 1}
    if bot_delivery_mode != 'missing_capabilities': result['bot_replies'] = 1
    return web.json_response(result)

async def enroll(request):
    return web.json_response({'device_id': '11111111-1111-4111-8111-111111111111', 'device_token': 'fixture-device-token', 'installation_id': 'fixture-installation'})

async def bot_reply(request):
    rid = request.match_info['rid']
    if request.method == 'PUT':
        body = await request.json()
        rpc_requests.append({'method': 'bot.reply.put', 'params': {**body, 'id': rid}})
        if body.get('profile') != 'research' or body.get('session_id') not in ('bot-tip', 'bot-next-tip'):
            return web.json_response({'error': 'wrong bot'}, status=400)
        paths = ['/fixture/uploads/' + ref['filename'] for ref in body.get('attachments', [])]
        text = '\n'.join([body['text']] + ['[User attached file: ' + path + ']' for path in paths]).strip()
        bot_replies.setdefault(rid, {'route': 'session' if bot_delivery_mode == 'session' else 'owner',
            'status': 'queued', 'reply': 'Bot replied to ' + body['text'], 'session_id': body['session_id'],
            'paths': paths, 'text': text, 'reads': 0, 'mode': bot_delivery_mode})
        if bot_delivery_mode == 'lost_ack': return web.json_response({'error': 'lost acknowledgement'}, status=503)
    if rid not in bot_replies: return web.json_response({'error': 'not found'}, status=404)
    reply = bot_replies[rid]
    if request.method == 'DELETE': rpc_requests.append({'method': 'bot.reply.cancel', 'params': {'id': rid}})
    if request.method == 'DELETE' and reply['status'] == 'queued': reply['status'] = 'cancelled'
    elif request.method == 'GET' and reply['status'] not in ('cancelled', 'settled'):
        reply['reads'] += 1
        if reply['mode'] == 'owner_failed': reply.update(status='failed', error='Fixture bot turn failed')
        elif reply['mode'] == 'owner_lost': reply.update(status='ambiguous', error='Fixture bot owner lost')
        elif reply['mode'] != 'queued_forever': reply['status'] = 'settled' if reply['reads'] >= 2 else 'claimed'
    return web.json_response({k: v for k, v in reply.items() if k not in ('reads', 'mode')})

async def upload_file(request):
    body = await request.json()
    key = body['upload_id']
    data = base64.b64decode(body['content_base64'], validate=True)
    existing = uploaded_files.setdefault(key, b'')
    assert body['offset'] == len(existing)
    uploaded_files[key] += data
    length = len(uploaded_files[key])
    return web.json_response({'offset': length, 'complete': length == body['total'],
                              'path': '/fixture/uploads/' + body['filename'] if length == body['total'] else None})

async def websocket(request):
    if request.query.get('ticket') != 'one-time-fixture-ticket':
        return web.Response(status=401)
    ws=web.WebSocketResponse()
    await ws.prepare(request)
    attachments = []
    submitted_photos = 0
    navigation_wait = False
    async def event(kind, payload, session='runtime-research'):
        await ws.send_json({'jsonrpc':'2.0','method':'event','params':{'session_id':session,'type':kind,'payload':payload}})
    async for frame in ws:
        if frame.type != web.WSMsgType.TEXT: continue
        message=frame.json(); method=message['method']; params=message.get('params',{}); result={}; error=None; error_code=-32602
        rpc_requests.append({'method': method, 'params': params})
        if method=='gateway.ping': result={'ok':True}
        elif method=='client.capabilities':
            if params != {'server_requests': True}: error='Invalid client capabilities'
            else: result={'server_requests':['approval','clarify'], 'declines_not_shown':True}
        elif method=='profiles.list':
            if params.get('include_sessions') is True:
                await asyncio.sleep(bot_lookup_delay)
            if params.get('include_sessions') is True and bot_mode == 'failure':
                error = 'Fixture bot lookup failed'
            else:
                rows = [dict(row) for row in profiles]
                if params.get('include_sessions') is True and bot_mode != 'unsupported':
                    for row in rows:
                        row['canonical_session'] = None
                        if row['name'] == 'research' and bot_mode != 'missing':
                            row['canonical_session'] = dict(id='bot-root', resolved_id='bot-next-tip' if bot_mode == 'advanced' else 'bot-tip',
                                root_title='Other Chat' if bot_mode == 'malformed' else 'Bot Chat', title='Compressed history',
                                preview=bot_preview, last_active=1800000000, message_count=1)
                        row['last_session'] = dict(id='saved-0', preview='Separate profile session message')
                result={'profiles':rows}
        elif method=='config.get':
            if params != {'key': 'profile'}: error='Only the gateway profile identity may be read'
            else: result={'home': launch_home} if launch_home is not None else {}
        elif method in ('commands.catalog', 'complete.slash', 'model.options', 'slash.exec', 'command.dispatch', 'session.status', 'session.title', 'config.set'):
            command_profile = params.get('profile')
            if method == 'complete.slash' and set(params) - {'text'}:
                error='invalid params for complete.slash: extra inputs are not permitted'
                error_code=4000
            elif method != 'complete.slash' and (command_profile not in ('research', 'default') or params.get('session_id') != 'runtime-'+command_profile):
                error='Commands must use the selected profile and runtime session id'
            elif method=='commands.catalog':
                builtin_pairs = [['/usage', 'Show current session token usage'], ['/reasoning', 'Set reasoning effort'], ['/status', 'Show session status'], ['/title', 'Name this session'], ['/model', 'Switch the model'], ['/new', 'Start a new session [name]'], ['/save', 'Save to a file [path]'], ['/compress', 'Compress this conversation']]
                extension_pairs = [[name, 'Fixture command'] for name in ['/fixture-reject', '/fixture-server-error', '/fixture-disconnect', '/fixture-direct', '/fixture-empty-send', '/fixture-alias']]
                result={
                    'pairs': builtin_pairs + extension_pairs + [['/fixture-skill', 'Run the research skill']],
                    'sub': {'/reasoning': ['high', 'low']},
                    'canon': {'/usage': '/usage', '/tokens': '/usage', '/reasoning': '/reasoning'},
                    'commands': {pair[0]: {'argument_mode': 'options' if pair[0] in ('/reasoning', '/model') else None, 'desktop': None} for pair in builtin_pairs},
                    'categories': [{'name': 'Session', 'pairs': builtin_pairs}, {'name': 'User commands', 'pairs': extension_pairs}],
                    'skills': {'/fixture-skill': {'usage': 3, 'origin': 'local'}},
                    'warning': 'Fixture catalog warning',
                }
            elif method=='complete.slash':
                if params.get('text')=='/':
                    # Completion is gateway-wide, including launch-profile skills.
                    result={'items': [{'text': 'usage', 'display': '/usage', 'meta': '', 'kind': 'command'}, {'text': 'fixture-skill', 'display': '/fixture-skill', 'meta': 'Launch-profile skill', 'kind': 'skill'}], 'replace_from': 1}
                elif params.get('text')=='/reasoning h':
                    result={'items': [{'text': 'high', 'display': 'high', 'meta': 'Use more reasoning', 'kind': 'command'}, {'text': 'hide', 'display': 'hide', 'meta': 'Hide reasoning text in the terminal', 'kind': 'command'}], 'replace_from': 11}
                elif params.get('text')=='/reasoning ':
                    levels = ['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra', 'show', 'hide', 'on', 'off', 'full', 'clamp', '--global']
                    result={'items': [{'text': value, 'display': value, 'meta': '', 'kind': 'command'} for value in levels], 'replace_from': 11}
                elif params.get('text') in ('/new', '/save'):
                    name = params['text']
                    result={'items': [{'text': name.lstrip('/'), 'display': name+' [terminal argument]', 'meta': 'Terminal-only behavior', 'kind': 'command'}], 'replace_from': 1}
                elif params.get('text')=='/tokens':
                    result={'items': [{'text': value, 'display': '/'+value, 'meta': 'Terminal usage description', 'kind': 'command'} for value in ['tokens', 'usage']], 'replace_from': 1}
                else:
                    result={'items': [{'text': 'usage', 'display': '/usage', 'meta': 'Show current session token usage', 'kind': 'command'}], 'replace_from': 1}
            elif method=='model.options':
                result={
                    'model': command_profile+'-current', 'provider': 'fixture-auth',
                    'providers': [
                        {'slug': 'fixture-auth', 'name': 'Fixture Provider', 'authenticated': True, 'models': [command_profile+'-current', command_profile+'-alternative']},
                        {'slug': 'fixture-locked', 'name': 'Unconfigured Provider', 'authenticated': False, 'models': ['unconfigured-model']},
                    ],
                }
            elif method=='session.status': result={'output': 'Research session is idle'}
            elif method=='session.title': result={'title': params.get('title', 'Fixture session'), 'session_key': 'saved-0'}
            elif method=='config.set':
                if params.get('key')=='model' and not params.get('confirm_expensive_model'):
                    result={'confirm_required': True, 'confirm_message': 'This model has a higher cost. Continue?'}
                elif params.get('key')=='reasoning' and params.get('scope')!='session': error='Reasoning must be scoped to this session'
                else: result={'applied': True, 'value': params.get('value')}
            elif method=='slash.exec':
                command=params.get('command', '').lstrip('/')
                if command=='usage': result={'output': 'Total tokens: 120', 'warning': 'Usage is estimated'}
                elif command=='fixture-reject': error='Fixture rejected the command'; error_code=4009
                elif command=='fixture-server-error': error='Fixture worker failed after possible effects'; error_code=5030
                elif command=='fixture-disconnect':
                    await ws.close()
                    break
                elif command.startswith('fixture-skill'):
                    error='skill command: use command.dispatch for /fixture-skill'; error_code=4018
                elif command.startswith('fixture-alias'):
                    error='Unknown command: fixture-alias'; error_code=4018
                elif command=='fixture-direct':
                    result={'type': 'send', 'message': 'Expanded fixture prompt', 'display': '/fixture-direct', 'notice': 'Fixture command expanded'}
                elif command=='fixture-empty-send': result={'type': 'send', 'message': ''}
                else: error='Unexpected slash command: '+command
            elif method=='command.dispatch':
                name=params.get('name')
                if name=='fixture-skill':
                    result={'type': 'skill', 'name': 'fixture-skill', 'message': 'Expanded research skill: '+params.get('arg', '')}
                elif name=='fixture-alias': result={'type': 'alias', 'target': 'usage'}
                else: error='Must not dispatch rejected commands: '+str(name)
        elif method in ('session.create','session.resume'):
            profile = params.get('profile')
            saved_id = params.get('session_id') if method == 'session.resume' and params.get('session_id') in ('bot-tip', 'bot-next-tip') else 'saved-default' if profile=='default' else 'saved-0'
            if profile not in ('research', 'default'): error='Wrong profile for session'
            elif method=='session.resume' and params.get('session_id')!=saved_id: error='Must resume stored id'
            else: result={'session_id':'runtime-'+profile,'stored_session_id':saved_id,'session_key':saved_id}
        elif method=='session.compress':
            result = {'info': {'stored_session_id': 'bot-next-tip'}, 'message': 'Bot context compressed'}
        elif method=='prompt.submit':
            if params.get('session_id')!='runtime-research': error='Must send runtime id'
            elif params.get('text')=='reject-submit': error='Fixture rejected the prompt'
            elif params.get('text')=='verify-cleanup' and attachments: error='Photos were not detached'
            else:
                submitted_photos = len(attachments)
                attachments.clear()
                if params.get('text')=='disconnect-submit':
                    await ws.close()
                    break
                result={'status':'submitted'}
        elif method=='image.attach_bytes':
            if params.get('session_id')!='runtime-research': error='Must attach to runtime id'
            elif params.get('filename')=='reject.jpg': error='Fixture rejected the photo'
            elif not base64.b64decode(params.get('content_base64',''), validate=True): error='Missing photo data'
            else:
                path='/fixture/images/'+str(len(attachments))+'-'+params['filename']
                attachments.append(path)
                if params.get('filename')=='disconnect.jpg':
                    await ws.close()
                    break
                result={'attached':True,'path':path,'count':len(attachments)}
        elif method=='image.detach':
            if params.get('session_id')!='runtime-research': error='Must detach from runtime id'
            else:
                path=params['path']
                detached=path in attachments
                if detached: attachments.remove(path)
                result={'detached':detached,'count':len(attachments)}
        elif method=='request.answer':
            expected = {'srq-approval': {'choice': 'once', 'all': False}, 'srq-clarify': {'answer': 'Staging'}}
            if params.get('result') != expected.get(params.get('id')): error='Wrong modern answer'
            else: result={'status':'ok'}
        elif method=='approval.respond':
            if params.get('request_id')!='approval-1' or params.get('choice')!='once': error='Wrong approval'
            else: result={'resolved':True}
        elif method=='approval.received': result={'received':True}
        elif method=='clarify.respond':
            if params.get('request_id')!='clarify-1' or params.get('answer')!='Staging': error='Wrong clarification'
            else: result={'status':'ok'}
        elif method=='session.interrupt': result={'interrupted':True}
        else: error='Unexpected method: '+method
        reply={'jsonrpc':'2.0','id':message['id']}
        reply.update({'error':{'code':error_code,'message':error}} if error else {'result':result})
        await ws.send_json(reply)
        if error: continue
        if method=='prompt.submit':
            await event('message.delta',{'text':'SHOULD NOT APPEAR'},session='another-bot')
            if params['text'] in ('modern-approval', 'modern-clarify'):
                kind = params['text'].removeprefix('modern-')
                payload = {'request_id':'approval-1','command':'echo hello','choices':['once','deny']} if kind == 'approval' else {'question':'Which environment?','choices':['Staging','Production']}
                await ws.send_json({'jsonrpc':'2.0','id':'srq-'+kind,'method':kind,'params':{'session_id':'runtime-research',**payload}})
            elif params['text']=='approval':
                await event('approval.request',{'request_id':'approval-1','command':'echo hello','choices':['once','deny']})
            elif params['text']=='clarify':
                await event('clarify.request',{'request_id':'clarify-1','question':'Which environment?','choices':['Staging','Production']})
            elif params['text']=='navigation-wait':
                navigation_wait = True
                await event('tool.start', {'name':'fixture-wait'})
            elif params['text']=='wait':
                await event('tool.start',{'name':'fixture-wait'})
            else:
                text=f'Received {submitted_photos} photos' if submitted_photos else 'Hello Hermes'
                await event('message.delta',{'text':text[:6]})
                await event('message.delta',{'text':text[6:]})
                await event('message.complete',{'text':text,'status':'completed'})
        elif method=='session.resume' and params.get('profile')=='default' and navigation_wait:
            navigation_wait = False
            await event('message.complete', {'text':'Background finished', 'status':'completed'})
        elif method=='request.answer':
            await event('message.complete',{'text':'Modern answer received','status':'completed'})
        elif method=='approval.respond':
            await event('message.complete',{'text':'Approved','status':'completed'})
        elif method=='clarify.respond':
            await event('message.complete',{'text':'Staging selected','status':'completed'})
        elif method=='session.interrupt':
            await event('message.complete',{'text':'Interrupted','status':'interrupted'})
    return ws

app=web.Application(middlewares=[auth])
for route, handler in [('api/health',health),('api/auth/me',me),('api/profiles',profile_list),('api/sessions',sessions),('api/sessions/{sid}/messages',messages),('api/fixture/stats',fixture_stats),('api/ws',websocket)]:
    app.router.add_get('/hermes/'+route,handler)
app.router.add_get('/hermes/api/plugins/hermes-jr/v1/capabilities',upload_capabilities)
app.router.add_put('/hermes/api/plugins/hermes-jr/v1/uploads',upload_file)
app.router.add_post('/hermes/api/plugins/hermes-jr/v1/enroll',enroll)
app.router.add_route('*','/hermes/api/plugins/hermes-jr/v1/bot-replies/{rid}',bot_reply)
app.router.add_post('/hermes/api/auth/ws-ticket',ticket)
app.router.add_post('/hermes/api/fixture/identity',fixture_identity)
app.router.add_post('/hermes/api/fixture/bot',fixture_bot)
web.run_app(app,host='127.0.0.1',port=19119,print=lambda _: print('Fixture ready at 127.0.0.1:19119',flush=True),access_log=None)
