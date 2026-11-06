const fs = require('fs');
const log = (m) => { try { fs.appendFileSync(process.argv[2], m + '\n'); } catch (e) { console.log('logfail', e.message); } console.log(m); };
log('started pid=' + process.pid + ' ppid=' + process.ppid);
for (const s of ['SIGTERM', 'SIGINT', 'SIGBREAK', 'SIGHUP']) process.on(s, () => { log('got ' + s); process.exit(3); });
process.on('exit', (c) => log('exit ' + c));
setInterval(() => {}, 1000);
