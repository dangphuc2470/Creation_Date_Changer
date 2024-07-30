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
        public PointLatLng LatLng { get; set; }
        public string Name { get; set; }

        public MyLocation(PointLatLng latLng, string name)
        {
            LatLng = latLng;
            Name = name;
        }

        public string getLatLngString()
        {
            return LatLng.Lat + ", " + LatLng.Lng;
        }
    }
}
