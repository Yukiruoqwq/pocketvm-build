#!/usr/bin/python3
"""Live host-backed filesystem; no background copies or conflict-prone sync."""
import base64
import errno
import json
import os
import pwd
import urllib.request
try:
    from fuse import FUSE, FuseOSError, Operations
except ImportError:
    from fusepy import FUSE, FuseOSError, Operations

class Shared(Operations):
    def __init__(self):
        self.user = pwd.getpwnam('codex')
        self.http = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        self.endpoint = os.environ.get('POCKETVM_BASE', 'http://10.0.2.2:8474') + '/shared'
    def call(self, op, path, **fields):
        data = json.dumps(dict(op=op, path=path, **fields)).encode()
        try:
            req = urllib.request.Request(self.endpoint, data=data, headers={'Content-Type': 'application/json'})
            with self.http.open(req, timeout=15) as response:
                reply = json.load(response)
            if 'errno' in reply:
                raise FuseOSError(reply['errno'])
            return reply['result']
        except FuseOSError:
            raise
        except Exception:
            raise FuseOSError(errno.EIO)
    def getattr(self, path, fh=None):
        value = self.call('stat', path)
        value.update(st_uid=self.user.pw_uid, st_gid=self.user.pw_gid,
                     st_atime=value['st_mtime'], st_ctime=value['st_mtime'])
        return value
    def readdir(self, path, fh): return ['.', '..'] + self.call('list', path)
    def open(self, path, flags):
        self.getattr(path)
        if flags & os.O_TRUNC: self.truncate(path, 0)
        return 0
    def create(self, path, mode, fi=None): return self.call('create', path)
    def read(self, path, size, offset, fh):
        chunks = []
        while size:
            part = base64.b64decode(self.call('read', path, offset=offset, size=min(size, 262144)))
            chunks.append(part)
            if not part: break
            offset += len(part); size -= len(part)
        return b''.join(chunks)
    def write(self, path, data, offset, fh):
        written = 0
        while written < len(data):
            part = data[written:written + 262144]
            count = self.call('write', path, offset=offset+written, data=base64.b64encode(part).decode())
            if count != len(part): raise FuseOSError(errno.EIO)
            written += count
        return written
    def truncate(self, path, length, fh=None): return self.call('truncate', path, size=length)
    def mkdir(self, path, mode): return self.call('mkdir', path)
    def unlink(self, path): return self.call('unlink', path)
    def rmdir(self, path): return self.call('rmdir', path)
    def rename(self, old, new): return self.call('rename', old, target=new)
    def flush(self, path, fh): return 0
    def fsync(self, path, datasync, fh): return 0
    def release(self, path, fh): return 0

if __name__ == '__main__':
    FUSE(Shared(), '/home/codex/Shared', foreground=True, nothreads=True,
         allow_other=True, default_permissions=True, attr_timeout=0, entry_timeout=0, negative_timeout=0)
