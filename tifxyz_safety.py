#!/usr/bin/env python3
"""Vesuvius TIFXYZ safety preflight.

Audits coordinate-grid validity, bbox/scale consistency, predicts vc_flatten
allocation, and can write a provenance-preserving repaired copy.
"""
from __future__ import annotations
import argparse, hashlib, json, math, shutil
from pathlib import Path
import numpy as np
import tifffile


def sha256(p):
    h=hashlib.sha256()
    with open(p,'rb') as f:
        for b in iter(lambda:f.read(1<<20),b''): h.update(b)
    return h.hexdigest()


def load(root):
    root=Path(root); meta=json.loads((root/'meta.json').read_text())
    a={k:np.asarray(tifffile.imread(root/f'{k}.tif'),dtype=np.float64) for k in 'xyz'}
    if len({v.shape for v in a.values()}) != 1: raise ValueError('coordinate shape mismatch')
    p=np.stack([a['x'],a['y'],a['z']],-1)
    ok=np.isfinite(p).all(-1)&(p!=-1).all(-1)&(p[...,2]>0)
    return root,meta,p,ok


def spacing(p,ok,axis):
    if axis==1: d=p[:,1:]-p[:,:-1]; m=ok[:,1:]&ok[:,:-1]
    else: d=p[1:]-p[:-1]; m=ok[1:]&ok[:-1]
    x=np.linalg.norm(d,axis=-1)[m]; x=x[np.isfinite(x)&(x>0)]
    return None if not len(x) else float(np.median(x))


def audit(root):
    root,meta,p,ok=load(root); findings=[]
    if not ok.any(): findings.append({'severity':'error','code':'NO_VALID_VERTICES'})
    bbox=None
    if ok.any():
        q=p[ok]; bbox=[q.min(0).tolist(),q.max(0).tolist()]
        old=meta.get('bbox')
        if old is None or np.max(np.abs(np.asarray(old,float)-np.asarray(bbox)))>1e-3:
            findings.append({'severity':'warning','code':'STALE_OR_MISSING_BBOX','suggested':bbox})
    sx,sy=spacing(p,ok,1),spacing(p,ok,0); scale=meta.get('scale')
    suggested=None
    if sx and sy: suggested=[1/sx,1/sy]
    if not isinstance(scale,list) or len(scale)!=2 or min(scale)<=0:
        findings.append({'severity':'error','code':'INVALID_SCALE'})
    elif sx and sy:
        inv=[abs(sx-scale[0])/scale[0],abs(sy-scale[1])/scale[1]]
        product=[sx*scale[0],sy*scale[1]]
        expected=[1/scale[0],1/scale[1]]
        rel=[abs(sx-expected[0])/expected[0],abs(sy-expected[1])/expected[1]]
        if max(inv)<=.15 and min(product)>=4:
            findings.append({'severity':'error','code':'SCALE_RECIPROCAL_INVERSION','suggested':suggested})
        elif max(rel)>.15:
            findings.append({'severity':'warning','code':'SCALE_SPACING_MISMATCH','suggested':suggested})
    return {'root':str(root),'shape':list(p.shape[:2]),'valid':int(ok.sum()),'total':int(ok.size),
            'bbox':bbox,'declared_scale':scale,'measured_step':[sx,sy],'suggested_scale':suggested,
            'sha256':{k:sha256(root/f'{k}.tif') for k in 'xyz'},'findings':findings}


def flatten_plan(ux,uy,sx,sy,max_pixels=500_000_000):
    if not all(math.isfinite(v) and v>0 for v in (ux,uy,sx,sy)): raise ValueError('inputs must be positive finite')
    w=max(2,math.ceil(ux*sx)+1); h=max(2,math.ceil(uy*sy)+1); n=w*h; b=n*12
    return {'grid':[w,h],'pixels':n,'vec3f_bytes':b,'vec3f_gib':b/1024**3,
            'max_pixels':max_pixels,'safe':n<=max_pixels}


def repair(src,dst,force_scale=False):
    before=audit(src); src=Path(src); dst=Path(dst)
    if src.resolve()==dst.resolve(): raise ValueError('in-place repair disabled')
    if any(f['code']=='NO_VALID_VERTICES' for f in before['findings']): raise ValueError('no valid vertices')
    if dst.exists(): raise ValueError('destination exists')
    shutil.copytree(src,dst); meta=json.loads((dst/'meta.json').read_text()); changes={}
    if before['bbox'] is not None and meta.get('bbox')!=before['bbox']:
        changes['bbox']={'before':meta.get('bbox'),'after':before['bbox']}; meta['bbox']=before['bbox']
    codes={f['code'] for f in before['findings']}
    if 'SCALE_RECIPROCAL_INVERSION' in codes or (force_scale and 'SCALE_SPACING_MISMATCH' in codes):
        changes['scale']={'before':meta.get('scale'),'after':before['suggested_scale']}; meta['scale']=before['suggested_scale']
    meta['tifxyz_safety_repair']={'coordinate_sha256':before['sha256'],'changes':changes}
    (dst/'meta.json').write_text(json.dumps(meta,indent=2)+'\n')
    after=audit(dst)
    if any(f['severity']=='error' for f in after['findings']): shutil.rmtree(dst); raise ValueError('repair failed validation')
    (dst/'repair_manifest.json').write_text(json.dumps({'before':before,'after':after,'changes':changes},indent=2)+'\n')
    return {'before':before,'after':after,'changes':changes}


def main():
    ap=argparse.ArgumentParser(); sp=ap.add_subparsers(dest='cmd',required=True)
    a=sp.add_parser('audit'); a.add_argument('dir')
    p=sp.add_parser('flatten-plan'); p.add_argument('ux',type=float);p.add_argument('uy',type=float);p.add_argument('sx',type=float);p.add_argument('sy',type=float);p.add_argument('--max-pixels',type=int,default=500_000_000)
    r=sp.add_parser('repair');r.add_argument('src');r.add_argument('dst');r.add_argument('--force-scale',action='store_true')
    x=ap.parse_args()
    if x.cmd=='audit': out=audit(x.dir)
    elif x.cmd=='flatten-plan': out=flatten_plan(x.ux,x.uy,x.sx,x.sy,x.max_pixels)
    else: out=repair(x.src,x.dst,x.force_scale)
    print(json.dumps(out,indent=2))
    if x.cmd=='audit' and any(f['severity']=='error' for f in out['findings']): raise SystemExit(2)
    if x.cmd=='flatten-plan' and not out['safe']: raise SystemExit(2)

if __name__=='__main__': main()
