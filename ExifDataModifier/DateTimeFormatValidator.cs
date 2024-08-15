using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace ExifDataModifier
{
    public static class DateTimeFormatValidator
    {
        public static bool IsValidFormat(string format)
        {
            // Basic check for invalid characters (you can refine this)
            if (format.Any(c => !char.IsLetterOrDigit(c) && c != '/' && c != '-' && c != ':' && c != ' ' && c != '.'))
            {
                return false;
            }

            try
            {
                var sampleDateTime = DateTime.Now;
                var formattedString = sampleDateTime.ToString(format, CultureInfo.InvariantCulture);
                DateTime.ParseExact(formattedString, format, CultureInfo.InvariantCulture);
                return true;
            }
            catch (FormatException)
            {
                return false;
            }
        }
    }
}
