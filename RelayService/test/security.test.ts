import { env } from "cloudflare:workers";
import { reset, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { afterEach, describe, expect, it, vi } from "vitest";
import { Buffer } from "node:buffer";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import worker from "../src/index";
import { unwrap } from "../src/http";
import { admissionData } from "../src/app-attest";
import { issueTicket } from "../src/setup-ticket";
import { newToken, tokenHash } from "../src/protocol";

let count=0;
async function request(path: string, method="GET", token?: string, body?: unknown, required=false, ticket?:string) {
  return worker.fetch(new Request("https://relay.test"+path,{method,headers:{"CF-Connecting-IP":`198.18.${Math.floor(++count/250)}.${count%250}`, ...(token?{Authorization:"Bearer "+token}:{}), ...(ticket?{"X-Hermes-Setup":ticket}:{}), ...(body!==undefined?{"Content-Type":"application/json"}:{})}, ...(body!==undefined?{body:JSON.stringify(body)}:{})}),required?{...env,APP_ATTEST_MODE:"required"}:env);
}
afterEach(async()=>{ await reset(); vi.restoreAllMocks(); });
describe("protected capacity",()=>{
  it("keeps a legacy host's spent allowance when the full directory verifies",async()=>{
    const admission=env.ADMISSION.getByName('service'), id=crypto.randomUUID();
    await runInDurableObject(admission,(_instance,state)=>{
      for(let i=0;i<250;i++) { const key=i===0?id:crypto.randomUUID(); state.storage.sql.exec('INSERT INTO admitted VALUES(?,?,0)',key,'legacy:'+key); }
    });
    expect(await admission.reserveSetup('migration','verified-phone',Date.now()+1000_000)).toBe(true);
    for(let i=0;i<5;i++) expect(await admission.push(id)).toBe(true);
    unwrap(await admission.promote(id,'migration'));
    expect(await runInDurableObject(admission,(_instance,state)=>state.storage.sql.exec("SELECT used FROM counters WHERE name='pushes:verified-phone'").one().used)).toBe(5);
    expect(await runInDurableObject(admission,(_instance,state)=>state.storage.sql.exec("SELECT COUNT(*) AS count FROM guarantees WHERE identity IN (?,?)",'legacy:'+id,'verified-phone').one().count)).toBe(1);
    for(let i=0;i<305;i++) expect(await admission.push(id)).toBe(true);
    expect(await admission.push(id)).toBe(false);
  });
  it("does not charge shared requests or setups for invalid routes, fields, or credentials",async()=>{
    const install=await (await request('/v1/installations','POST',undefined,{})).json<{installation_id:string;host_token:string}>();
    const admission=env.ADMISSION.getByName('service');
    const before=await admission.status();
    for(let i=0;i<10;i++) {
      expect((await request('/v1/pairing/intents','POST',undefined,{phone_public_key:'invalid'})).status).toBe(400);
      expect((await request('/v1/pairing/unknown')).status).toBe(401);
      expect((await request(`/v1/installations/${install.installation_id}/devices`,'GET',newToken())).status).toBe(401);
      expect((await request(`/v1/installations/${install.installation_id}/other`,'PUT',install.host_token,{})).status).toBe(404);
      expect((await request(`/v1/installations/${install.installation_id}/devices`,'POST',install.host_token,{private:'invalid'})).status).toBe(400);
    }
    const after=await admission.status();
    expect(after.today.requests).toBe(before.today.requests);
    expect(after.today.setups).toBe(before.today.setups);
  });
  it("shares an identity's allowance across companions and protects other identities and setup",async()=>{
    const admission=env.ADMISSION.getByName('service');
    const ids=[];
    for(const [intent,identity] of [['a','phone'],['b','phone'],['c','honest']]) {
      expect(await admission.reserveSetup(intent,identity,Date.now()+1000_000)).toBe(true);
      ids.push(unwrap(await admission.reserveTicket(intent,await tokenHash(newToken()))));
    }
    for(let i=0;i<310;i++) expect(await admission.push(ids[i%2])).toBe(true);
    expect(await admission.push(ids[0])).toBe(false);
    for(let i=0;i<10;i++) expect(await admission.push(ids[2])).toBe(true);
    expect(await admission.push(ids[2])).toBe(false);
    expect(await admission.setupPush()).toBe(true);
    // Seed only the bounded burst counters; use the public RPC to check the last guarantee.
    await runInDurableObject(admission,(_instance,state)=>{
      const day=Math.floor(Date.now()/86400_000);
      state.storage.sql.exec("INSERT OR REPLACE INTO counters VALUES('request_burst',?,37500)",day);
      state.storage.sql.exec("INSERT OR REPLACE INTO counters VALUES('requests:phone',?,250)",day);
    });
    expect(await admission.admissionResult(ids[0])).toBe('capacity');
    expect(await admission.admissionResult(ids[2])).toBe('admitted');
  });
  it("reserves a ticket once, keeps the original identity, and reclaims abandoned objects",async()=>{
    const admission=env.ADMISSION.getByName('service'), intent=newToken(), identity=newToken(), hash=await tokenHash(newToken());
    expect(await admission.reserveSetup(intent,identity,Date.now()+1000_000)).toBe(true);
    const ids=await Promise.all(Array.from({length:8},()=>admission.reserveTicket(intent,hash).then(result=>unwrap(result))));
    expect(new Set(ids).size).toBe(1);
    await expect(admission.reserveTicket(intent,await tokenHash(newToken())).then(result=>unwrap(result))).rejects.toThrow('reservation_used');
    const id=ids[0], object=env.INSTALLATIONS.getByName(id);
    await object.initialize(id,hash);
    await object.initialize(id,hash);
    await runInDurableObject(admission,(_instance,state)=>{state.storage.sql.exec('UPDATE admitted SET provisional_until=1 WHERE id=?',id);});
    expect(await admission.registered(id)).toBe(false);
    await runDurableObjectAlarm(admission);
    expect(await runInDurableObject(object,(_instance,state)=>state.storage.sql.exec("SELECT COUNT(*) AS count FROM sqlite_master WHERE type='table'").one().count)).toBe(0);
    expect((await admission.status()).installations).toBe(0);
    const keep=newToken();
    await admission.reserveSetup(keep,identity,Date.now()+1000_000);
    const live=unwrap(await admission.reserveTicket(keep,hash)); await admission.promote(live,keep);
    await admission.reserveSetup('other',newToken(),Date.now()+1000_000); await admission.promote(live,'other');
    expect(await runInDurableObject(admission,(_instance,state)=>state.storage.sql.exec('SELECT identity FROM admitted WHERE id=?',live).one().identity)).toBe(identity);
  });
  it("requires a verified reservation before public registration and preserves lost-response retries",async()=>{
    const phone=newToken(), issued=Math.floor(Date.now()/1000), intent=newToken();
    const result=await issueTicket(env,phone,'https://relay.test',{intent_id:intent,issued});
    const hostToken=newToken();
    expect((await request('/v1/installations','POST',undefined,{},true)).status).toBe(428);
    expect((await request('/v1/installations','POST',undefined,{setup_ticket:result.ticket,host_token:hostToken},true)).status).toBe(410);
    await env.ADMISSION.getByName('service').reserveSetup(intent,newToken(),result.intent.expires_at*1000);
    const body={setup_ticket:result.ticket,host_token:hostToken};
    const first=await request('/v1/installations','POST',undefined,body,true), second=await request('/v1/installations','POST',undefined,body,true);
    expect(first.status).toBe(201); expect(second.status).toBe(201);
    expect(await first.json()).toEqual(await second.json());
  });
});

describe("verified admission retries",()=>{
  it("allocates no rows for public challenges and rejects invalid proofs before reservation",async()=>{
    const apps=env.APP_ADMISSION.getByName('apps'), key=newToken(),phone=newToken();
    let challenge='';
    for(let i=0;i<30;i++) {
      const response=await request('/v1/app-attest/challenges','POST',undefined,{key_id:key,phone_public_key:phone},true);
      expect(response.status).toBe(200); challenge=(await response.json<{challenge:string}>()).challenge;
    }
    expect(await runInDurableObject(apps,(_instance,state)=>state.storage.sql.exec('SELECT COUNT(*) AS count FROM challenges').one().count)).toBe(0);
    expect((await request('/v1/pairing/intents','POST',undefined,{key_id:key,phone_public_key:phone,challenge,proof:'AA',assertion:false},true)).status).toBe(403);
    expect((await env.ADMISSION.getByName('service').status()).today.setups).toBe(0);
  });
  it("consumes an assertion once and rejects changed or concurrent replay",async()=>{
    const key=generateKeyPairSync('ec',{namedCurve:'prime256v1'}), keyId=newToken(), phone=newToken(), apps=env.APP_ADMISSION.getByName('apps');
    const publicKey=key.publicKey.export({type:'spki',format:'pem'}).toString();
    await runInDurableObject(apps,(_instance,state)=>{state.storage.sql.exec('INSERT INTO app_keys VALUES(?,?,0,?)',keyId,publicKey,Date.now());});
    const challenge=unwrap(await apps.challenge(keyId,phone,'https://relay.test'));
    const hash=(data:Buffer|string)=>createHash('sha256').update(data).digest();
    const data=admissionData('https://relay.test',challenge.challenge,keyId,phone);
    const auth=Buffer.concat([hash(env.APP_ATTEST_APP_ID),Buffer.from([0,0,0,0,1])]);
    const signature=sign('sha256',Buffer.concat([auth,hash(data)]),key.privateKey);
    const entry=(name:string,value:Buffer)=>{const text=Buffer.from(name);return Buffer.concat([Buffer.from([0x60+text.length]),text,Buffer.from([0x58,value.length]),value]);};
    const proof=Buffer.concat([Buffer.from([0xa2]),entry('authenticatorData',auth),entry('signature',signature)]).toString('base64url');
    const results=await Promise.all(Array.from({length:5},()=>apps.verify(keyId,phone,'https://relay.test',challenge.challenge,proof,true).then(result=>unwrap(result))));
    expect(new Set(results.map(x=>x.intent_id)).size).toBe(1);
    await expect(apps.verify(keyId,newToken(),'https://relay.test',challenge.challenge,proof,true).then(result=>unwrap(result))).rejects.toThrow('invalid_challenge');
    await expect(apps.verify(keyId,phone,'https://relay.test',challenge.challenge,proof+'AA',true).then(result=>unwrap(result))).rejects.toThrow('challenge_used');
    const otherPhone=newToken(), next=unwrap(await apps.challenge(keyId,otherPhone,'https://relay.test'));
    await expect(apps.verify(keyId,otherPhone,'https://relay.test',next.challenge,proof,true).then(result=>unwrap(result))).rejects.toThrow('app_verification_failed');
    // Continue through the public ticket and registration endpoints with a verified assertion.
    const verification={key_id:keyId,phone_public_key:phone,challenge:challenge.challenge,proof,assertion:true};
    const response=await request('/v1/pairing/intents','POST',undefined,verification,true);
    expect(response.status).toBe(201);
    const intent=await response.json<{ticket:string;intent_id:string;owner_token:string}>();
    expect(await (await request('/v1/pairing/intents','POST',undefined,verification,true)).json()).toEqual(intent);
    const hostToken=newToken();
    const install=await (await request('/v1/installations','POST',undefined,{setup_ticket:intent.ticket,host_token:hostToken},true)).json<{installation_id:string}>();
    // A private development deployment uses the same required policy. This test overrides only that object's environment.
    await runInDurableObject(env.SETUP_INTENTS.getByName(intent.intent_id),(instance)=>{
      const target=instance as unknown as {env:Env}; target.env={...target.env,APP_ATTEST_MODE:'required'};
    });
    const claimId=crypto.randomUUID(), claimToken=newToken(), path='/v1/pairing/'+intent.intent_id;
    expect((await request(path+'/claims','POST',hostToken,{claim_id:claimId,claim_token:claimToken,installation_id:install.installation_id,host_public_key:newToken(),host_name:'Fixture',commitment:newToken()},true,intent.ticket)).status).toBe(200);
    for(const [action,field,token,value] of [['key','phone_ephemeral',intent.owner_token,newToken()],['reveal','host_ephemeral',claimToken,newToken()],['confirm','confirmation',intent.owner_token,newToken()],['enrollment','envelope',claimToken,newToken()+newToken()]]) {
      expect((await request(`${path}/claims/${claimId}/${action}`,'PUT',token,{[field]:value},true,intent.ticket)).status).toBe(200);
    }
    expect(await runInDurableObject(env.ADMISSION.getByName('service'),(_instance,state)=>state.storage.sql.exec('SELECT provisional_until FROM admitted WHERE id=?',install.installation_id).one().provisional_until)).toBe(0);
    // Simulate loss of the final phone acknowledgement. Expiry must keep the established installation.
    await runInDurableObject(env.ADMISSION.getByName('service'),(_instance,state)=>{state.storage.sql.exec('UPDATE setup_reservations SET expires=1');});
    await runDurableObjectAlarm(env.ADMISSION.getByName('service'));
    expect(await env.ADMISSION.getByName('service').registered(install.installation_id)).toBe(true);
  });
});
