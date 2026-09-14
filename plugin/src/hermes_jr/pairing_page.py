"""Private, self-contained pairing page. No server, external assets, or analytics."""
from __future__ import annotations
import asyncio
import base64
import hashlib
import html
import io
import json
import os
from pathlib import Path
import time
import sys
import uuid
import webbrowser
import qrcode
import qrcode.image.svg


def render(payload):
    compact = json.dumps(payload, separators=(",", ":"))
    qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_L, border=4)
    qr.add_data(compact)
    qr.make(fit=True)
    image = qr.make_image(image_factory=qrcode.image.svg.SvgPathImage)
    stream = io.BytesIO(); image.save(stream)
    svg = stream.getvalue().decode()
    svg = svg[svg.index('<svg'):]
    expires = int(payload['expires_at'])
    script = '''const deadline=EXPIRES*1000;function tick(){const remaining=Math.max(0,Math.ceil((deadline-Date.now())/1000));const label=document.getElementById('expiry');if(!remaining){document.getElementById('qr').replaceChildren();document.getElementById('qr').textContent='This code has expired.';label.textContent='Ask Hermes for a new pairing code.';}else{label.textContent='Code expires in '+Math.floor(remaining/60)+':'+String(remaining%60).padStart(2,'0');}}tick();setInterval(tick,1000);setTimeout(()=>location.reload(),3000);'''.replace('EXPIRES', str(expires))
    digest = base64.b64encode(hashlib.sha256(script.encode()).digest()).decode()
    return '''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'sha256-DIGEST'; base-uri 'none'; form-action 'none'">
<title>Connect your iPhone · Hermes Jr.</title><style>
*{box-sizing:border-box}body{margin:0;background:#f4f1e9;color:#24362c;font-family:ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;padding:36px 20px}main{max-width:900px;margin:auto}.brand{font-size:21px;font-weight:750;letter-spacing:-.8px;display:flex;align-items:center;gap:10px}.mark{display:inline-grid;place-items:center;background:#284d3c;color:#f4f1e9;width:40px;height:40px;border-radius:13px;font-family:Georgia,serif;font-size:26px}.tag{margin:7px 0 32px;color:#6b766b;font-size:14px}.card{background:#fffdf8;border:1px solid #dedfd4;border-radius:28px;padding:38px;box-shadow:0 16px 44px #293a2810}h1{font-size:clamp(28px,5vw,40px);letter-spacing:-1.4px;line-height:1.12;margin:0 0 12px}p{line-height:1.6;color:#657064}.intro{max-width:560px;margin:0 0 30px}.layout{display:grid;grid-template-columns:minmax(260px,1fr) minmax(240px,1fr);gap:36px;align-items:start}#qr{background:white;border:1px solid #e4e5dc;border-radius:18px;min-height:300px;display:grid;place-items:center;padding:12px;overflow:hidden}#qr svg{display:block;width:100%;height:auto;max-height:390px}#expiry{text-align:center;font-size:13px;margin:10px 0 0}ol{padding:0;margin:0;list-style:none;counter-reset:step}li{counter-increment:step;position:relative;padding:0 0 22px 38px;line-height:1.5;font-size:15px}li:before{content:counter(step);position:absolute;left:0;top:0;width:25px;height:25px;border-radius:50%;background:#e9eee3;color:#365541;text-align:center;font-weight:650}li strong{display:block;margin-bottom:4px}li span{color:#687366}details{border-top:1px solid #e4e5dc;padding-top:18px;font-size:13px}summary{cursor:pointer;color:#435c4a}code{display:block;word-break:break-word;font-size:12px;line-height:1.8;background:#f2f4ed;padding:12px;border-radius:9px;margin-top:10px}footer{font-size:12px;color:#778174;margin:20px 5px;line-height:1.6}.private{margin:25px 0 0;font-size:13px;color:#4e6857}@media(max-width:680px){body{padding:22px 14px}.card{padding:25px 20px}.layout{grid-template-columns:1fr;gap:25px}#qr{min-height:0}.tag{margin-bottom:24px}}
</style></head><body><main><div class="brand"><span class="mark" aria-hidden="true">h</span>Hermes Jr.</div><div class="tag">Your agent. In your pocket.</div><section class="card"><h1>Let’s connect your iPhone.</h1><p class="intro">Scan this code in Hermes Jr. to bring your conversations with you.</p><div class="layout"><div><div id="qr" role="img" aria-label="Private Hermes Jr. pairing QR code">QR</div><p id="expiry">This code lasts ten minutes.</p></div><div><ol><li><strong>Open Hermes Jr.</strong><span>Choose the option to scan a pairing code.</span></li><li><strong>Scan this code.</strong><span>Your phone will connect automatically.</span></li><li><strong>You’re ready.</strong><span>Your conversations will appear in Jr. There’s nothing to copy or confirm.</span></li></ol></div></div><p class="private">Private pairing · This page stays on your computer. No tracking or external requests.</p></section><footer>Keep this page private. It lets your phone request access to your agent.</footer></main><script>SCRIPT</script></body></html>'''.replace('DIGEST', digest).replace('QR</div>', svg + '</div>').replace('SCRIPT', script)


def create_page(payload, directory):
    directory = Path(directory) / 'pairing-pages'
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory.chmod(0o700)
    # Remove this feature's expired artifacts, never arbitrary user files.
    for old in directory.glob('pair-*.html'):
        if not old.is_symlink() and old.is_file() and old.stat().st_mtime < time.time() - 600:
            old.unlink()
    path = directory / ('pair-' + uuid.uuid4().hex + '.html')
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as stream:
        stream.write(render(payload))
    return path.resolve()


def open_page(payload, directory):
    path = create_page(payload, directory)
    try:
        # Do not launch a blocking text browser from a headless SSH/agent session.
        headless = sys.platform.startswith('linux') and not (os.getenv('DISPLAY') or os.getenv('WAYLAND_DISPLAY'))
        opened = False if headless else webbrowser.open(path.as_uri(), new=2)
    except (webbrowser.Error, OSError):
        opened = False
    print('Your private pairing page is ready:')
    print('[Open your pairing page](' + path.as_uri() + ')')
    if opened:
        print('Asked your browser to open it. Scan the code in Hermes Jr., then come back here to finish connecting.')
    else:
        print('A browser could not be opened here. Open the HTML file on your computer, or have Hermes send it to you through your private chat.')
    print('The code expires in ten minutes. Keep the page private.')
    print('Waiting for your phone. Scan the code in Hermes Jr.; connecting will finish automatically.')
    print('HERMES: Give the user the page link, then keep this command running or poll its existing process. Do not request fingerprints or approval. On success, continue setup yourself and keep the reply brief.')
    sys.stdout.flush()
    return path


async def wait_for_phone(state, device_id, expires, page):
    """Wait in the installing agent's command; pairing authority stays in the bridge."""
    while time.time() < expires:
        device = state.device(device_id)
        if not device:
            raise ValueError("This code is no longer available. Create a new one.")
        if device['approved'] and device['public_key']:
            finish_page(page, "You’re connected.", "Your conversations are ready in Hermes Jr. You can close this page.")
            print('Your iPhone is connected. Continue setup; no user approval is needed.')
            return
        await asyncio.sleep(1)
    finish_page(page, "This code has expired.", "Ask Hermes for a new code, then scan it in Jr.")
    raise ValueError("The pairing code expired before a phone connected")


def finish_page(page, title, message):
    page = Path(page)
    content = '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src \'none\'; style-src \'unsafe-inline\'"><title>Hermes Jr.</title><style>body{background:#f4f1e9;color:#24362c;font-family:system-ui;text-align:center;padding:15vh 24px}h1{font-size:40px;letter-spacing:-1px}p{line-height:1.6}small{font-weight:700}</style><small>Hermes Jr.</small><h1>'+html.escape(title)+'</h1><p>'+html.escape(message)+'</p>'
    temporary = page.with_suffix('.tmp')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(content)
        os.replace(temporary, page)
    finally:
        temporary.unlink(missing_ok=True)
