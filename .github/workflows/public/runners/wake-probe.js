addEventListener('wakeProbe', (resolve, reject, args) => {
 try {
 const now = Date.now();
 let log = [];
 try {
 const raw = CapacitorKV.get('wake_probe_log').value;
 if (raw) log = JSON.parse(raw);
 } catch (e) { log = []; }
 log.push(now);
 if (log.length > 500) log = log.slice(-500);
 CapacitorKV.set('wake_probe_log', JSON.stringify(log));
 CapacitorKV.set('wake_probe_last', String(now));
 console.log('[wake-probe] tick #' + log.length + ' at ' + new Date(now).toISOString());
 resolve();
 } catch (err) { reject(err); }
});
