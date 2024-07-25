using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Data;
using System.Drawing;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace ExifDataModifier
{
    public partial class ProgressForm : Form
    {
        public ProgressForm()
    {
        InitializeComponent();
    }

    public void UpdateProgress(int progress, string message)
    {
        progressBar1.Value = progress;
        lbProgress.Text = message;
    }
    }
}
