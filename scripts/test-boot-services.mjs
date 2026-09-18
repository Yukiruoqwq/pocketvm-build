import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';

const source = readFileSync(new URL('../guest/pocketvm-boot.sh', import.meta.url), 'utf8');
const sshFunction = source.match(/^queue_ssh\(\) \{\r?\n[\s\S]*?^\}/m)?.[0];
const bash = process.platform === 'win32' ? 'C:/Program Files/Git/bin/bash.exe' : 'bash';
function exercise(keygenStatus, enableStatus) {
  assert.ok(sshFunction);
  return execFileSync(bash, ['-c', `
    ssh-keygen() { echo keygen; return ${keygenStatus}; }
    systemctl() {
      echo "systemctl $*"
      case "$*" in
        'enable ssh.service') return ${enableStatus} ;;
        'start --no-block ssh.service') return 0 ;;
        *) echo 'blocking/unexpected service operation' >&2; return 99 ;;
      esac
    }
    ${sshFunction.replaceAll('\r', '')}
    queue_ssh
    echo "result:$?"
  `], {encoding:'utf8'});
}
test('SSH boot job is enabled then queued without waiting for network.target', () => {
  const result = exercise(0,0);
  assert.match(result,/systemctl enable ssh.service\nsystemctl start --no-block ssh.service\nresult:0/);
});
test('SSH prerequisite failure does not queue an invalid startup job', () => {
  for (const result of [exercise(1,0),exercise(0,1)]) {
    assert.match(result,/result:1/);
    assert.doesNotMatch(result,/systemctl start/);
  }
});
