import json
from pathlib import Path
import numpy as np
import tifffile
import tifxyz_safety as s


def fixture(root: Path, scale=(0.05,0.05), bbox=None):
    root.mkdir(); yy,xx=np.meshgrid(np.arange(12),np.arange(14),indexing='ij')
    x=(100+20*xx).astype('float32'); y=(200+20*yy).astype('float32'); z=(1000+.2*xx+.3*yy).astype('float32')
    for k,a in zip('xyz',(x,y,z)): tifffile.imwrite(root/f'{k}.tif',a)
    p=np.stack([x,y,z],-1); actual=[p.reshape(-1,3).min(0).tolist(),p.reshape(-1,3).max(0).tolist()]
    (root/'meta.json').write_text(json.dumps({'scale':list(scale),'bbox':actual if bbox is None else bbox}))


def test_clean(tmp_path):
    d=tmp_path/'d'; fixture(d); r=s.audit(d); assert not r['findings']


def test_inversion(tmp_path):
    d=tmp_path/'d'; fixture(d,scale=(20,20),bbox=[[0,0,0],[1,1,1]])
    codes={f['code'] for f in s.audit(d)['findings']}; assert 'SCALE_RECIPROCAL_INVERSION' in codes


def test_issue_1379_exact_allocation():
    r=s.flatten_plan(18090,15162.22,19.997318267822266,19.996686935424805)
    assert r['grid']==[361753,303196]; assert r['pixels']==109682062588; assert r['vec3f_bytes']==1316184751056; assert not r['safe']


def test_corrected_scale_allocation():
    r=s.flatten_plan(18090,15162.22,.05,.05); assert r['grid']==[906,760]; assert r['safe']


def test_repair_copy_only(tmp_path):
    a=tmp_path/'a'; b=tmp_path/'b'; fixture(a,scale=(20,20),bbox=[[0,0,0],[1,1,1]])
    original=(a/'meta.json').read_bytes(); r=s.repair(a,b); assert (a/'meta.json').read_bytes()==original
    assert r['before']['sha256']==r['after']['sha256']; assert not [f for f in r['after']['findings'] if f['severity']=='error']
