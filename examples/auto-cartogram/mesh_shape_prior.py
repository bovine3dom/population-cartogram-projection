"""Optional component-wide shape prior for the experimental mesh."""
import numpy as np
from scipy.sparse import coo_matrix


class RegionShapePrior:
    """Fit a scaled source shape, with free translation but no rotation."""
    def __init__(self,vertices,triangles,pieces,targets):
        rows=[];columns=[];data=[];groups=[];areas=[];reference=[]
        for group,parts in enumerate(pieces):
            for triangle,piece in parts:
                point=np.asarray(piece.centroid.coords[0]);corners=vertices[triangles[triangle]]
                uv=np.linalg.solve((corners[1:]-corners[0]).T,point-corners[0])
                weights=[1-uv.sum(),*uv];index=len(groups)
                rows.extend([index]*3);columns.extend(triangles[triangle]);data.extend(weights)
                groups.append(group);areas.append(piece.area);reference.append(point)
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
