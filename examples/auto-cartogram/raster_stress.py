"""Repel whole tile silhouettes with cached signed-distance correlations."""
import numpy as np
from scipy.ndimage import distance_transform_edt
from scipy.signal import fftconvolve

from concave_stress import ConcaveStress
from shape_stress import Stress


def bilinear(array,x,y):
    if x<0 or y<0 or x>=array.shape[1]-1 or y>=array.shape[0]-1:return 0.,np.zeros(2)
    ix,iy=int(np.floor(x)),int(np.floor(y));tx,ty=x-ix,y-iy
    a,b=array[iy,ix:ix+2];c,d=array[iy+1,ix:ix+2]
    value=(1-ty)*((1-tx)*a+tx*b)+ty*((1-tx)*c+tx*d)
    gradient=np.array([(1-ty)*(b-a)+ty*(d-c),(1-tx)*(c-a)+tx*(d-b)])
    return float(value),gradient


class RasterStress(Stress):
    border_targets=ConcaveStress.border_targets

    def __init__(self,tiles,centres,required,collision=100.,spring=1.,anchor=.01,spatial=.03,gap=.8):
        super().__init__(tiles,centres,required,collision,spring,anchor,spatial,gap)
        self.fields=[];self.potentials={}
        margin=max(3,int(np.ceil(gap))+2)
        for c in self.labels:
            points=np.array(sorted(tiles[c]));centre=points.mean(axis=0)
            low=points.min(axis=0)-margin;high=points.max(axis=0)+margin
            mask=np.zeros(tuple((high-low+1)[::-1]),dtype=bool)
            mask[points[:,1]-low[1],points[:,0]-low[0]]=True
            outside=distance_transform_edt(~mask);inside=distance_transform_edt(mask)
            signed=np.where(mask,-inside+.5,outside-.5)
            penalty=np.maximum(gap-signed,0.)**2
            self.fields.append((mask.astype(float),penalty,low-centre))

    def pair_energy_gradient(self,a,b,positions):
        ma,pa,oa=self.fields[a];mb,pb,ob=self.fields[b];key=(a,b)
        if key not in self.potentials:
            potential=fftconvolve(pb,ma[::-1,::-1],mode='full')+fftconvolve(pa,mb[::-1,::-1],mode='full')[::-1,::-1]
            potential[np.abs(potential)<1e-8]=0.
            self.potentials[key]=np.maximum(potential,0.)
        offset=positions[a]-positions[b]+oa-ob+np.array(ma.shape[::-1])-1
        value,gradient=bilinear(self.potentials[key],*offset)
        return .5*self.collision*value,.5*self.collision*gradient
