"""Optional component-wide shape prior for the experimental mesh."""
import numpy as np
from scipy.sparse import coo_matrix


def moment_samples(geometry):
    """Four points with the polygon's exact mean and second moment."""
    centre=np.asarray(geometry.centroid.coords[0])
    def ring_moment(ring):
        points=np.asarray(ring.coords)-centre;a=points[:-1];b=points[1:]
        cross=a[:,0]*b[:,1]-b[:,0]*a[:,1];sign=np.sign(cross.sum())
        xx=np.sum(cross*(a[:,0]**2+a[:,0]*b[:,0]+b[:,0]**2))/12
        yy=np.sum(cross*(a[:,1]**2+a[:,1]*b[:,1]+b[:,1]**2))/12
        xy=np.sum(cross*(2*a[:,0]*a[:,1]+a[:,0]*b[:,1]+b[:,0]*a[:,1]+2*b[:,0]*b[:,1]))/24
        return sign*np.array([[xx,xy],[xy,yy]])
    def moment(g):
        if g.geom_type=='Polygon':return ring_moment(g.exterior)-sum((ring_moment(r) for r in g.interiors),np.zeros((2,2)))
        return sum((moment(p) for p in g.geoms if p.area>0),np.zeros((2,2)))
    covariance=moment(geometry)/geometry.area
    values,vectors=np.linalg.eigh(covariance)
    if values.min() < -1e-10*max(float(values.max()),1e-30):raise ValueError('Invalid source second moment')
    offsets=(vectors*np.sqrt(2*np.maximum(values,0))).T
    return np.concatenate((centre+offsets,centre-offsets))


class RegionShapePrior:
    """Fit a scaled source shape, with free translation but no rotation."""
    def __init__(self,vertices,triangles,pieces,targets):
        rows=[];columns=[];data=[];groups=[];areas=[];reference=[]
        for group,parts in enumerate(pieces):
            for triangle,piece in parts:
                corners=vertices[triangles[triangle]]
                for point in moment_samples(piece):
                    uv=np.linalg.solve((corners[1:]-corners[0]).T,point-corners[0])
                    weights=[1-uv.sum(),*uv];index=len(groups)
                    rows.extend([index]*3);columns.extend(triangles[triangle]);data.extend(weights)
                    groups.append(group);areas.append(piece.area/4);reference.append(point)
        self.groups=np.asarray(groups);areas=np.asarray(areas)
        totals=np.bincount(self.groups,weights=areas,minlength=len(pieces))
        if np.any(totals<=0):raise ValueError('Empty shape-prior component')
        self.weights=areas/totals[self.groups]
        self.interpolation=coo_matrix((data,(rows,columns)),shape=(len(groups),len(vertices))).tocsr()
        self.means=coo_matrix((self.weights,(groups,np.arange(len(groups)))),shape=(len(pieces),len(groups))).tocsr()
        self.reference=np.asarray(reference)*np.sqrt(np.asarray(targets)/totals)[self.groups,None]

    def evaluate(self,vertices):
        difference=self.interpolation@vertices-self.reference
        residual=difference-(self.means@difference)[self.groups]
        cost=np.sum(self.weights[:,None]*residual**2)
        gradient=self.interpolation.T@(2*self.weights[:,None]*residual)
        return float(cost),gradient
