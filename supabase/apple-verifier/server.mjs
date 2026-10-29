// Node 22+ sidecar: the official Apple SDK needs complete node:crypto.X509Certificate.
import {createServer} from 'node:http';
import {Readable} from 'node:stream';
import * as sdk from '@apple/app-store-server-library';
import {appleRootDERBase64} from '../functions/film-device/apple-roots.mjs';
import {createAppleVerifier} from '../functions/film-device/subscriptions.mjs';
import {createVerifierHandler} from './service.mjs';
const verify=createAppleVerifier({sdk,roots:appleRootDERBase64.map(c=>Buffer.from(c,'base64')),getenv:key=>process.env[key]});
const handler=createVerifierHandler({secret:process.env.APPLE_VERIFIER_SHARED_SECRET,verify});
const server=createServer(async(req,res)=>{
 try{
  const request=new Request('http://localhost'+req.url,{method:req.method,headers:req.headers,...(req.method==='POST'?{body:Readable.toWeb(req),duplex:'half'}:{})});
  const result=await handler(request);res.writeHead(result.status,Object.fromEntries(result.headers));res.end(Buffer.from(await result.arrayBuffer()));
 }catch{res.writeHead(500,{'cache-control':'no-store'});res.end();}
});
server.requestTimeout=60000;server.headersTimeout=10000;
server.listen(Number(process.env.PORT||8080),process.env.HOST||'127.0.0.1');
