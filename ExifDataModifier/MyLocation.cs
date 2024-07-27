using GMap.NET;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace ExifDataModifier
{
    public class MyLocation
    {
        PointLatLng latLng;
        String name;
        public MyLocation(PointLatLng latLng, String name)
        {
            this.latLng = latLng;
            this.name = name;
        }

        public PointLatLng getLatLng()
        {
            return latLng;
        }

        public String getName()
        {
            return name;
        }
        public void setName(String name)
        {
            this.name = name;
        }

        public void setLatLng(PointLatLng latLng)
        {
            this.latLng = latLng;
        }

        public string getLatLngString()
        {
            return latLng.Lat + ", " + latLng.Lng;
        }
    }
}
