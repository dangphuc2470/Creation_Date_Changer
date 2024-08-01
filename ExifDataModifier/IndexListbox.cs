using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System;
using System.Windows.Forms;
using System.Drawing;
using System.Windows.Forms;

namespace ExifDataModifier
{
    public class IndexListView : ListView
    {
        private ColumnHeader indexColumn;
        private ColumnHeader PathColumn;
        private int index = 0;

        public IndexListView()
        {
            // Create the index column
            indexColumn = new ColumnHeader();
            indexColumn.Text = "N.";
            indexColumn.Width = 25;

            // Create the path column
            PathColumn = new ColumnHeader();
            PathColumn.Text = "Path";
            PathColumn.Width = -2;
            Columns.Add(indexColumn);
            Columns.Add(PathColumn);
            View = View.Details;
            FullRowSelect = true;
            this.ItemActivate += new EventHandler(IndexListView_ItemActivate);
            this.MouseClick += new MouseEventHandler(IndexListView_MouseClick);
        }

        public void AddItem(string path)
        {
            if (InvokeRequired)
            {
                Invoke(new Action<string>(AddItem), path);
                return;
            }

            ListViewItem item = new ListViewItem();
            item.Text = index.ToString();
            item.SubItems.Add(path);
            Items.Add(item);
            index++;
        }

        public void ClearItems()
        {
            if (InvokeRequired)
            {
                Invoke(new Action(ClearItems));
                return;
            }
            Items.Clear();
            index = 0;
        }

        private void IndexListView_ItemActivate(object sender, EventArgs e)
        {
            if (this.SelectedItems.Count > 0)
            {
                ListViewItem selectedItem = this.SelectedItems[0];
                ToolTip tt = new ToolTip();
                tt.Show(selectedItem.SubItems[1].Text, this, selectedItem.Bounds.Left, selectedItem.Bounds.Bottom, 1000);
            }
        }

        private void IndexListView_MouseClick(object sender, MouseEventArgs e)
{
    if (this.SelectedItems.Count > 0)
    {
        ListViewItem selectedItem = this.SelectedItems[0];
        ToolTip tt = new ToolTip();
        tt.Show(selectedItem.SubItems[1].Text, this, selectedItem.Bounds.Left, selectedItem.Bounds.Bottom, 1000);
    }
}
    }
}