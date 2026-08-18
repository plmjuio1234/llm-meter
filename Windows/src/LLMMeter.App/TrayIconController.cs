using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace LLMMeter.App;

internal sealed class TrayIconController : IDisposable
{
    private readonly Forms.NotifyIcon notifyIcon;
    private readonly Forms.ContextMenuStrip contextMenu;
    private readonly Action toggleWindow;
    private readonly Action exitApplication;
    private bool disposed;

    public TrayIconController(Action toggleWindow, Action exitApplication)
    {
        this.toggleWindow = toggleWindow;
        this.exitApplication = exitApplication;
        contextMenu = new Forms.ContextMenuStrip();
        contextMenu.Items.Add("Open LLM Meter", null, (_, _) => this.toggleWindow());
        contextMenu.Items.Add(new Forms.ToolStripSeparator());
        contextMenu.Items.Add("Exit", null, (_, _) => this.exitApplication());

        notifyIcon = new Forms.NotifyIcon
        {
            Icon = Drawing.SystemIcons.Application,
            Text = "LLM Meter",
            ContextMenuStrip = contextMenu,
            Visible = true
        };
        notifyIcon.MouseClick += NotifyIcon_MouseClick;
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        notifyIcon.MouseClick -= NotifyIcon_MouseClick;
        notifyIcon.Visible = false;
        notifyIcon.Dispose();
        contextMenu.Dispose();
    }

    private void NotifyIcon_MouseClick(
        object? sender,
        Forms.MouseEventArgs args)
    {
        if (args.Button == Forms.MouseButtons.Left)
        {
            toggleWindow();
        }
    }
}
