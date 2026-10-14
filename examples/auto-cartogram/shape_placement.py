"""Find the nearest integer translation with no occupied-cell collision."""
import numpy as np
from scipy.signal import fftconvolve


def place(cells,desired,blocked,maximum_radius=8192,translation_bounds=None):
    cx=sum(x for x,y in cells)/len(cells);cy=sum(y for x,y in cells)/len(cells)
    lower,upper=np.asarray(translation_bounds if translation_bounds is not None else [[-np.inf,-np.inf],[np.inf,np.inf]],dtype=float)
    if lower.shape!=(2,) or upper.shape!=(2,) or np.isnan([lower,upper]).any() or np.isposinf(lower).any() or np.isneginf(upper).any() or np.any(lower>upper):raise ValueError('Invalid translation bounds')
    lower=np.ceil(lower);upper=np.floor(upper)
    if np.any(lower>upper):raise ValueError('No integer translation within bounds')
    origin=tuple(int(v) for v in np.clip([round(desired[0]-cx),round(desired[1]-cy)],lower,upper))
    moved={(x+origin[0],y+origin[1]) for x,y in cells}
    if not moved & blocked:return moved
    x0=min(x for x,y in cells);y0=min(y for x,y in cells)
    width=max(x for x,y in cells)-x0+1;height=max(y for x,y in cells)-y0+1
    kernel=np.zeros((height,width),dtype=np.float32)
    for x,y in cells:kernel[y-y0,x-x0]=1
    radius=8
    while radius<=maximum_radius:
        left=origin[0]+x0-radius;bottom=origin[1]+y0-radius
        grid=np.zeros((height+2*radius,width+2*radius),dtype=np.float32)
        for x,y in blocked:
            if 0<=x-left<grid.shape[1] and 0<=y-bottom<grid.shape[0]:grid[y-bottom,x-left]=1
        overlaps=fftconvolve(grid,kernel[::-1,::-1],mode='valid')
        yy,xx=np.nonzero(overlaps<.5)
        shifts=np.column_stack((xx-radius+origin[0],yy-radius+origin[1]))
        valid=np.all((shifts>=lower)&(shifts<=upper),axis=1);yy=yy[valid];xx=xx[valid]
        if len(xx):
            dx=xx-radius;dy=yy-radius
            index=np.lexsort((dy,dx,dx*dx+dy*dy,np.maximum(np.abs(dx),np.abs(dy))))[0]
            shift=(origin[0]+int(dx[index]),origin[1]+int(dy[index]))
            moved={(x+shift[0],y+shift[1]) for x,y in cells}
            if moved & blocked:raise AssertionError('Convolution missed a cell collision')
            return moved
        radius*=2
    raise ValueError('Placement search exhausted')


def place_all(tiles,desired,required=None,gap=False):
    occupied=set();halos={};result={}
    for c in sorted(tiles,key=lambda c:(-len(tiles[c]),c)):
        blocked=set(occupied)
        for other,halo in halos.items():
            if gap or (required is not None and tuple(sorted((c,other))) not in required):blocked.update(halo)
        moved=place(tiles[c],desired[c],blocked);result[c]=moved;occupied.update(moved)
        halos[c]={(x+dx,y+dy) for x,y in moved for dx,dy in [(1,0),(-1,0),(0,1),(0,-1)]}-moved
    return result
