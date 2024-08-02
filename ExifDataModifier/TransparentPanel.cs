using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace ExifDataModifier
{
    public class TransparentPanel : Panel
    {
        public TransparentPanel()
        {
            this.SetStyle(ControlStyles.SupportsTransparentBackColor, true);
            this.BackColor = Color.Transparent;
        }

        protected override void OnPaintBackground(PaintEventArgs e)
        {
            // Do not paint background to achieve transparency
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            // Ensure the panel itself is transparent
            e.Graphics.FillRectangle(new SolidBrush(Color.FromArgb(0, this.BackColor)), this.ClientRectangle);
            base.OnPaint(e);
        }
    }

}
