<%@ Page Language="C#" %>
<%@ Register Src="~/album.ashx" TagPrefix="photo" TagName="album" %>

<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">

<html xmlns="http://www.w3.org/1999/xhtml" >
<head runat="server">
    <title>Page hosted Photo Album</title>
    <link rel='Stylesheet' type='text/css' href='Album.css' />
</head>
<body>
    <form id="form1" runat="server">
    <div>
        <photo:album runat="server" ID="Album1" />
    </div>
    </form>
</body>
</html>
