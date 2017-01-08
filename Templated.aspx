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
        <photo:album runat="server" ID="Album1" EnableViewState="false">
            <FolderModeTemplate>
                <h1 class="center"><asp:Label runat="server" Text='<%# Eval("Title") %>' /></h1>
                <div>
                    <asp:HyperLink runat="server"
                        NavigateUrl='<%# Eval("ParentFolder.Link") %>'
                        Visible='<%# (Eval("ParentFolder") != null) %>'
                        CssClass='<%# Eval("ImageDivCssClass") %>'>
                        <asp:Image runat="server" ImageUrl='<%# Eval("ParentFolder.IconUrl") %>'
                            AlternateText='<%# Eval("BackToParentTooltip") %>' /><br />
                        <asp:Label runat="server" Text='<%# Eval("BackToParentText") %>' />
                    </asp:HyperLink>
                    <asp:Repeater runat="server" ID="SubFolders" DataSource='<%# Eval("SubFolders") %>'>
                        <ItemTemplate>
                            <asp:HyperLink runat="server" NavigateUrl='<%# Eval("Link") %>' CssClass='<%# Eval("Owner.ImageDivCssClass") %>'>
                                <asp:Image runat="server" ImageUrl='<%# Eval("IconUrl") %>'
                                    AlternateText='<%# Eval("Name", (string)Eval("Owner.OpenFolderTooltipFormatString")) %>' /><br />
                                <asp:Label runat="server" Text='<%# Eval("Name") %>' />
                            </asp:HyperLink>
                        </ItemTemplate>
                    </asp:Repeater>
                    <asp:Repeater runat="server" ID="Images" DataSource='<%# Eval("Images") %>'>
                        <ItemTemplate>
                            <div runat="server" class='<%# Eval("Owner.ImageDivCssClass") %>'>
                                <asp:HyperLink runat="server" NavigateUrl='<%# Eval("Link") %>'>
                                    <asp:Image runat="server" ImageUrl='<%# Eval("IconUrl") %>'
                                        ToolTip='<%# Eval("Owner.DisplayImageTooltip") %>'
                                        AlternateText='<%# Eval("Caption") %>' />
                                </asp:HyperLink><br />&nbsp;
                            </div>
                        </ItemTemplate>
                    </asp:Repeater>
                </div>
                <div>
                    <asp:HyperLink runat="server" NavigateUrl='<%# Eval("PermaLink") %>'
                        Text="PermaLink (Right click and choose &quot;Add to favorites&quot; or &quot;Bookmark this link&quot;)" />
                </div>
            </FolderModeTemplate>
            <PageModeTemplate>
                <h1 class="center"><asp:Label runat="server" Text='<%# Eval("Title") %>' /></h1>
                <table><tr>
                    <td valign="top">
                        <asp:HyperLink runat="server" NavigateUrl='<%# Eval("ParentFolder.Link") %>'>
                            <asp:Image runat="server" ImageUrl='<%# Eval("ParentFolder.IconUrl") %>'
                                AlternateText='<%# Eval("BackToParentTooltip") %>' />
                        </asp:HyperLink>
                        <asp:HyperLink runat="server" NavigateUrl='<%# Eval("PreviousImage.Link") %>' Visible='<%# Eval("PreviousImage") != null %>'>
                            <asp:Image runat="server" ImageUrl='<%# Eval("PreviousImage.IconUrl") %>'
                                AlternateText='<%# Eval("PreviousImage.Caption") %>' ToolTip='<%# Eval("PreviousImageTooltip") %>' />
                        </asp:HyperLink><br />
                        <a href="javascript:void(0)" onclick="photoAlbumDetails(&quot;&quot;)" class="albumDetailsLink">Details</a>
                        <div id="_details" style="display:none">
                            <asp:Repeater runat="server" ID="MetaData" DataSource='<%# Eval("Image.MetaData") %>'>
                                <HeaderTemplate><table></HeaderTemplate>
                                <ItemTemplate>
                                    <tr><td colspan="2" class="albumMetaSectionHead"><%# Eval("Key") %></td></tr>
                                    <asp:Repeater runat="server" ID="Tags" DataSource='<%# Eval("Value") %>'>
                                        <ItemTemplate>
                                            <tr>
                                                <td class="albumMetaName"><%# Eval("Key") %></td>
                                                <td class="albumMetaValue"><%# Eval("Value") %></td>
                                            </tr>
                                        </ItemTemplate>
                                   </asp:Repeater>
                                </ItemTemplate>
                                <FooterTemplate></table></FooterTemplate>
                            </asp:Repeater>
                        </div>
                    </td>
                    <td valign="top" rowspan="2">
                        <asp:HyperLink runat="server" NavigateUrl='<%# Eval("Image.Url") %>' Target="_blank">
                            <asp:Image runat="server" AlternateText='<%# Eval("DisplayFullResolutionTooltip") %>'
                                ImageUrl='<%# Eval("Image.PreviewUrl") %>' />
                        </asp:HyperLink><br />
                        <asp:HyperLink runat="server" NavigateUrl='<%# Eval("PermaLink") %>'
                            Text="PermaLink (Right click and choose &quot;Add to favorites&quot; or &quot;Bookmark this link&quot;)" />
                    </td>
                    <td runat="server" valign="top" rowspan="2" visible='<%# Eval("NextImage") != null %>'>
                        <asp:HyperLink runat="server" NavigateUrl='<%# Eval("NextImage.Link") %>'>
                            <asp:Image runat="server" ImageUrl='<%# Eval("NextImage.IconUrl") %>'
                                AlternateText='<%# Eval("NextImage.Caption") %>' ToolTip='<%# Eval("NextImageTooltip") %>' />
                        </asp:HyperLink>
                    </td>
                </tr></table>
            </PageModeTemplate>
        </photo:album>
    </div>
    </form>
</body>
</html>
