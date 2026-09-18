const test = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync,mkdtempSync,writeFileSync,rmSync} = require('node:fs');
const {tmpdir} = require('node:os');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const source = readFileSync(path.join(__dirname,'../guest/pocketvm-repair.sh'),'utf8').replaceAll('\r','');
const bash = process.platform === 'win32' ? 'C:/Program Files/Git/bin/bash.exe' : 'bash';
function exercise({marker=false, packages=true, runtime=true, host=true}={}) {
  const dir=mkdtempSync(path.join(tmpdir(),'pocketvm-repair-'));
  const posix=dir.replaceAll('\\','/').replace(/^([A-Za-z]):/,(_,drive)=>'/'+drive.toLowerCase());
  try {
    writeFileSync(path.join(dir,'provision.sh'),'echo INSTALL\n');
    writeFileSync(path.join(dir,'share.sh'),'echo SHARE\n');
    if(marker) writeFileSync(path.join(dir,'install-complete'),'');
    const script=source.replaceAll('/var/lib/pocketvm',posix).replaceAll('/run/pocketvm-installation.json',posix+'/installation.json').replaceAll('/usr/local/sbin/pocketvm-provision.sh',posix+'/provision.sh').replaceAll('/usr/local/lib/pocketvm/pocketvm-shared-setup.sh',posix+'/share.sh');
    const run=`
dpkg-query() { echo ${packages?'installed':'unpacked'}; }
timeout() { shift; "$@"; }
runuser() { return ${runtime?0:1}; }
curl() { echo HOST_CHECK; }
python3() { return ${host?0:1}; }
${script}
test -f '${posix}/install-complete' && echo MARKED
true
`;
    return execFileSync(bash,['-c',run],{encoding:'utf8'});
  } finally { rmSync(dir,{recursive:true,force:true}); }
}
test('legacy healthy installation migrates without running installer',()=>{
  const result=exercise(); assert.match(result,/MARKED/); assert.doesNotMatch(result,/INSTALL/); assert.match(result,/SHARE/);
});
test('completion marker cannot conceal missing packages or broken runtime',()=>{
  for(const options of [{marker:true,packages:false},{marker:true,runtime:false}]) assert.match(exercise(options),/INSTALL/);
});
test('healthy dependencies alone cannot mark an unfinished installation complete',()=>{
  const result=exercise({host:false}); assert.match(result,/INSTALL/); assert.doesNotMatch(result,/MARKED/);
});
test('completed healthy installation skips both migration and reinstall',()=>{
  const result=exercise({marker:true}); assert.doesNotMatch(result,/HOST_CHECK|INSTALL/); assert.match(result,/SHARE/);
});
