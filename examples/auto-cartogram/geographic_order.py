"""Penalize reversed source directions without constructing contact paths."""
import numpy as np


class GeographicOrder:
    def __init__(self,labels,rows,margin=1.):
        primary={};population={}
        for c in labels:
            country=rows[c]['country_id'];mass=float(rows[c]['group_population'])
            population[country]=population.get(country,0.)+mass
            if country not in primary or (mass,c)>(float(rows[primary[country]]['group_population']),primary[country]):primary[country]=c
        major={c for country,c in primary.items() if population[country]>=10_000_000}
        constraints=[]
        for a,ca in enumerate(labels):
            for b in range(a+1,len(labels)):
                cb=labels[b];same=rows[ca]['country_id']==rows[cb]['country_id']
                if not same and not(ca in major and cb in major):continue
                for axis,(low,high) in enumerate([('west','east'),('south','north')]):
                    delta=(float(rows[cb][low])+float(rows[cb][high])-float(rows[ca][low])-float(rows[ca][high]))/2
                    if abs(delta)<(1 if same else 3) or (axis==0 and abs(delta)>180):continue
                    constraints.append((2*a+axis,2*b+axis,1 if delta>0 else -1,.05 if same else margin,.1 if same else 1.))
        data=np.array(constraints,dtype=float).reshape(-1,5)
        self.a=data[:,0].astype(int);self.b=data[:,1].astype(int)
        self.sign=data[:,2];self.margin=data[:,3];self.weight=data[:,4]
        self.count=len(constraints)

    def objective(self,positions):
        flat=positions.ravel();gap=np.maximum(self.margin-self.sign*(flat[self.b]-flat[self.a]),0.)
        value=.5*np.dot(self.weight,gap*gap);gradient=np.zeros_like(flat)
        force=self.weight*gap*self.sign
        np.add.at(gradient,self.a,force);np.add.at(gradient,self.b,-force)
        return float(value),gradient.reshape(positions.shape)
