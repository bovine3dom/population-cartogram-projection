"""Use a smooth interpolation of whole-silhouette collision costs."""
import numpy as np
from scipy.interpolate import RectBivariateSpline
from scipy.ndimage import gaussian_filter

from raster_stress import RasterStress


class SmoothRasterStress(RasterStress):
    def __init__(self,*args,**kwargs):
        super().__init__(*args,**kwargs);self.splines={}
        self.low-=2;self.high+=2

    def pair_energy_gradient(self,a,b,positions):
        key=(a,b)
        if key not in self.splines:
            super().pair_energy_gradient(a,b,positions)
            potential=gaussian_filter(self.potentials[key],.6,mode='constant')
            self.splines[key]=RectBivariateSpline(np.arange(potential.shape[0]),np.arange(potential.shape[1]),potential,s=0)
        ma,pa,oa=self.fields[a];mb,pb,ob=self.fields[b]
        x,y=positions[a]-positions[b]+oa-ob+np.array(ma.shape[::-1])-1
        array=self.potentials[key]
        if x<0 or y<0 or x>=array.shape[1]-1 or y>=array.shape[0]-1:return 0.,np.zeros(2)
        spline=self.splines[key];value=float(spline.ev(y,x))
        if value<=0:return 0.,np.zeros(2)
        gradient=np.array([spline.ev(y,x,dy=1),spline.ev(y,x,dx=1)],dtype=float)
        return .5*self.collision*value,.5*self.collision*gradient
