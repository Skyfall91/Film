/** No account reads, migrations or device requests until an explicit release. */
export function withRollout(handler, enabled) {
  return request => enabled() === 'true'
    ? handler(request)
    : new Response(JSON.stringify({error:'service_not_enabled'}), {
        status:503,
        headers:{'content-type':'application/json','cache-control':'no-store'}
      });
}
