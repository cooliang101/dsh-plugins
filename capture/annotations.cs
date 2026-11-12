using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

public sealed class CaptureOverlay : Form
{
    private readonly Pen border = new Pen(Color.FromArgb(76, 141, 255), 2);
    private readonly Font hintFont = new Font("Microsoft YaHei", 11);
    private readonly Font sizeFont = new Font("Consolas", 10, FontStyle.Bold);
    private readonly Brush hintBackground = new SolidBrush(Color.FromArgb(190, 20, 24, 32));
    private readonly Brush sizeBackground = new SolidBrush(Color.FromArgb(210, 28, 34, 48));
    private Bitmap screenshot;
    private Bitmap dimmed;
    private Rectangle selection;
    private Rectangle visibleSelection;
    private Rectangle sizeBounds;
    private string sizeText;

    private CaptureAnnotations Annotations { get; set; }
    public string Hint { get; set; }

    public CaptureOverlay()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                 ControlStyles.OptimizedDoubleBuffer, true);
    }

    public void SetScreenshot(Bitmap bitmap)
    {
        var background = (Bitmap)bitmap.Clone();
        try
        {
            using (Graphics graphics = Graphics.FromImage(background))
            using (var shade = new SolidBrush(Color.FromArgb(115, 0, 0, 0)))
                graphics.FillRectangle(shade, 0, 0, background.Width, background.Height);
        }
        catch
        {
            background.Dispose();
            throw;
        }
        if (dimmed != null) dimmed.Dispose();
        dimmed = background;
        screenshot = bitmap;
        Invalidate();
    }

    private Rectangle HintBounds()
    {
        Size size = TextRenderer.MeasureText(Hint, hintFont);
        return new Rectangle((int)Math.Round((ClientSize.Width - size.Width) / 2.0),
                             40, size.Width + 24, size.Height + 8);
    }

    public void SetSelection(Rectangle region, Rectangle monitorBounds, CaptureAnnotations annotations)
    {
        if (selection == region && Annotations == annotations) return;
        Rectangle previousSelection = visibleSelection;
        Rectangle previousSize = sizeBounds;
        bool hintChanged = selection.IsEmpty != region.IsEmpty;
        bool annotationsChanged = Annotations != annotations;

        selection = region;
        Annotations = annotations;
        visibleSelection = Rectangle.Intersect(region, monitorBounds);
        visibleSelection.Offset(-monitorBounds.X, -monitorBounds.Y);
        sizeBounds = Rectangle.Empty;
        if (!region.IsEmpty && region.IntersectsWith(monitorBounds))
        {
            sizeText = region.Width + " x " + region.Height;
            Size size = TextRenderer.MeasureText(sizeText, sizeFont);
            int x = (int)Math.Round(region.X - monitorBounds.X + (region.Width - size.Width) / 2.0);
            int y = Math.Max(region.Y - monitorBounds.Y - size.Height - 8, 4);
            sizeBounds = new Rectangle(x - 8, y, size.Width + 16, size.Height);
        }

        if (!hintChanged && !HasArea(previousSelection) && !HasArea(visibleSelection) &&
            !HasArea(previousSize) && !HasArea(sizeBounds)) return;

        using (var damage = new Region(Rectangle.Empty))
        {
            if (HasArea(previousSelection)) damage.Union(Rectangle.Inflate(previousSelection, 2, 2));
            if (HasArea(visibleSelection)) damage.Union(Rectangle.Inflate(visibleSelection, 2, 2));
            if (!annotationsChanged)
            {
                // The overlap away from either border still shows the same pixels.
                Rectangle overlap = Rectangle.Inflate(Rectangle.Intersect(previousSelection, visibleSelection), -2, -2);
                if (HasArea(overlap)) damage.Exclude(overlap);
            }
            damage.Union(previousSize);
            damage.Union(sizeBounds);
            if (hintChanged) damage.Union(HintBounds());
            damage.Intersect(ClientRectangle);
            Invalidate(damage);
        }
    }

    public void InvalidateAnnotations()
    {
        if (HasArea(visibleSelection)) Invalidate(visibleSelection);
    }

    private static bool HasArea(Rectangle rectangle)
    {
        return rectangle.Width > 0 && rectangle.Height > 0;
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        if (dimmed == null) base.OnPaintBackground(e);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        if (dimmed == null) return;
        Graphics graphics = e.Graphics;
        Rectangle clip = e.ClipRectangle;
        Rectangle selectedClip = Rectangle.Intersect(visibleSelection, clip);
        if (!HasArea(selectedClip) || selectedClip != clip)
            graphics.DrawImage(dimmed, clip, clip, GraphicsUnit.Pixel);
        if (HasArea(selectedClip))
        {
            if (Annotations == null)
                graphics.DrawImage(screenshot, selectedClip, selectedClip, GraphicsUnit.Pixel);
            else
                Annotations.Paint(graphics, PointToClient(selection.Location), selectedClip);
        }
        if (HasArea(visibleSelection) && Rectangle.Inflate(visibleSelection, 2, 2).IntersectsWith(clip))
            graphics.DrawRectangle(border, visibleSelection);

        if (selection.IsEmpty)
        {
            Rectangle hint = HintBounds();
            if (hint.IntersectsWith(clip))
            {
                graphics.FillRectangle(hintBackground, hint);
                graphics.DrawString(Hint, hintFont, Brushes.White, hint.X + 12, hint.Y + 4);
            }
        }
        else if (sizeBounds.IntersectsWith(clip))
        {
            graphics.FillRectangle(sizeBackground, sizeBounds);
            graphics.DrawString(sizeText, sizeFont, Brushes.White, sizeBounds.X + 8, sizeBounds.Y);
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            if (dimmed != null) dimmed.Dispose();
            border.Dispose();
            hintFont.Dispose();
            sizeFont.Dispose();
            hintBackground.Dispose();
            sizeBackground.Dispose();
        }
        base.Dispose(disposing);
    }
}

public sealed class CaptureAnnotations : IDisposable
{
    private const int MosaicSize = 10;
    private const int MosaicBrushSize = 3;
    private static readonly Color Ink = Color.FromArgb(239, 65, 65);
    private readonly Bitmap source;
    private readonly Bitmap composed;
    private readonly List<Mark> history = new List<Mark>();
    private Mark draft;

    private sealed class Mark
    {
        public readonly string Tool;
        public readonly Point Start;
        public Point End;
        public string Text;
        public readonly List<Point> Points = new List<Point>();
        public readonly HashSet<Point> Tiles = new HashSet<Point>();

        public Mark(string tool, Point start)
        {
            Tool = tool;
            Start = End = start;
            Points.Add(start);
        }
    }

    // Takes ownership of the unmarked selection, in selection-local pixels.
    public CaptureAnnotations(Bitmap source)
    {
        this.source = source;
        composed = (Bitmap)source.Clone();
    }

    public bool Drawing { get { return draft != null; } }
    public bool CanUndo { get { return history.Count > 0; } }

    public void Begin(string tool, Point point)
    {
        draft = new Mark(tool, point);
        if (tool == "mosaic") AddTiles(draft, point);
    }

    public void Move(Point point)
    {
        if (draft == null) return;
        point = new Point(Math.Max(0, Math.Min(point.X, source.Width - 1)),
                          Math.Max(0, Math.Min(point.Y, source.Height - 1)));
        if (point == draft.End) return;
        if (draft.Tool == "brush") draft.Points.Add(point);
        if (draft.Tool == "mosaic")
        {
            int dx = point.X - draft.End.X;
            int dy = point.Y - draft.End.Y;
            int steps = Math.Max(Math.Abs(dx), Math.Abs(dy));
            for (int i = 1; i <= steps; i += 3)
                AddTiles(draft, new Point(draft.End.X + dx * i / steps, draft.End.Y + dy * i / steps));
            AddTiles(draft, point);
        }
        draft.End = point;
    }

    public void End(Point point)
    {
        if (draft == null) return;
        Move(point);
        Mark mark = draft;
        draft = null;
        if (mark.Tool == "rectangle" && (mark.Start.X == mark.End.X || mark.Start.Y == mark.End.Y)) return;
        if (mark.Tool == "arrow" && mark.Start == mark.End) return;
        Commit(mark);
    }

    public void CancelStroke() { draft = null; }

    public void AddText(Point point, string text)
    {
        if (!String.IsNullOrWhiteSpace(text)) Commit(new Mark("text", point) { Text = text });
    }

    private void Commit(Mark mark)
    {
        using (Graphics g = Graphics.FromImage(composed)) Render(g, mark);
        history.Add(mark);
    }

    public void Undo()
    {
        if (!CanUndo) return;
        history.RemoveAt(history.Count - 1);
        using (Graphics g = Graphics.FromImage(composed))
        {
            g.DrawImageUnscaled(source, 0, 0);
            foreach (Mark mark in history) Render(g, mark);
        }
    }

    public void Paint(Graphics g, Point origin, Rectangle clip)
    {
        GraphicsState state = g.Save();
        try
        {
            g.SetClip(clip, CombineMode.Intersect);
            g.TranslateTransform(origin.X, origin.Y);
            g.DrawImageUnscaled(composed, 0, 0);
            if (draft != null) Render(g, draft);
        }
        finally { g.Restore(state); }
    }

    public void Save(string path)
    {
        composed.Save(path, System.Drawing.Imaging.ImageFormat.Png);
    }

    private void AddTiles(Mark mark, Point point)
    {
        int tileX = point.X / MosaicSize;
        int tileY = point.Y / MosaicSize;
        int radius = MosaicBrushSize / 2;
        for (int y = Math.Max(0, tileY - radius); y <= tileY + radius && y * MosaicSize < source.Height; y++)
            for (int x = Math.Max(0, tileX - radius); x <= tileX + radius && x * MosaicSize < source.Width; x++)
                mark.Tiles.Add(new Point(x * MosaicSize, y * MosaicSize));
    }

    private void Render(Graphics g, Mark mark)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var pen = new Pen(Ink, 3))
        using (var brush = new SolidBrush(Ink))
        {
            pen.StartCap = pen.EndCap = LineCap.Round;
            pen.LineJoin = LineJoin.Round;
            switch (mark.Tool)
            {
                case "rectangle":
                    g.DrawRectangle(pen, Math.Min(mark.Start.X, mark.End.X), Math.Min(mark.Start.Y, mark.End.Y),
                        Math.Abs(mark.End.X - mark.Start.X), Math.Abs(mark.End.Y - mark.Start.Y));
                    break;
                case "arrow":
                    if (mark.Start == mark.End) break;
                    using (var tip = new AdjustableArrowCap(4, 5))
                    {
                        pen.CustomEndCap = tip;
                        g.DrawLine(pen, mark.Start, mark.End);
                    }
                    break;
                case "brush":
                    if (mark.Points.Count == 1) g.FillEllipse(brush, mark.Start.X - 1, mark.Start.Y - 1, 3, 3);
                    else g.DrawLines(pen, mark.Points.ToArray());
                    break;
                case "text":
                    using (var font = new Font("Microsoft YaHei", 18, FontStyle.Regular, GraphicsUnit.Pixel))
                        g.DrawString(mark.Text, font, brush, mark.Start);
                    break;
                case "mosaic":
                    foreach (Point tile in mark.Tiles)
                    {
                        int width = Math.Min(MosaicSize, source.Width - tile.X);
                        int height = Math.Min(MosaicSize, source.Height - tile.Y);
                        brush.Color = source.GetPixel(tile.X + width / 2, tile.Y + height / 2);
                        g.FillRectangle(brush, tile.X, tile.Y, width, height);
                    }
                    break;
            }
        }
    }

    public void Dispose()
    {
        composed.Dispose();
        source.Dispose();
    }
}
