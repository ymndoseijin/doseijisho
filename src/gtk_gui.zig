const std = @import("std");
const unicode = @import("std").unicode;
const defs = @import("defs.zig");

// why don't namespaces work?
const Entry = defs.Entry;
const c = defs.c;
const allocator = defs.allocator;
const toNullTerminated = defs.toNullTerminated;
const message = defs.message;
const Dictionary = defs.Dictionary;

var current_entries = std.ArrayList(Entry).init(allocator);

var entry_buffer: *c.GtkEntryBuffer = undefined;
var description_widget: *c.GtkWidget = undefined;
var lv: [*c]c.GtkWidget = undefined;
var dict_lv: [*c]c.GtkWidget = undefined;
var description_attributes: *c.PangoAttrList = undefined;
var name_attributes: *c.PangoAttrList = undefined;
var library: []Dictionary = undefined;

var current_phrase: [*c]const u8 = message;

var dict_index: usize = 0;
var entry_index: usize = 0;

pub const log_level: std.log.Level = .info;

fn gtkSetMargins(widget: *c.GtkWidget, size: i32) void {
    c.gtk_widget_set_margin_bottom(widget, size);
    c.gtk_widget_set_margin_end(widget, size);
    c.gtk_widget_set_margin_start(widget, size);
    c.gtk_widget_set_margin_top(widget, size);
}

fn gtkSetup(arg_factory: ?*c.GtkListItemFactory, arg_listitem: ?*c.GtkListItem, arg_user_data: c.gpointer) callconv(.C) void {
    var factory = arg_factory;
    _ = @TypeOf(factory);
    var listitem = arg_listitem;
    var user_data = arg_user_data;
    _ = @TypeOf(user_data);
    var lb: [*c]c.GtkWidget = c.gtk_label_new(null);
    c.gtk_list_item_set_child(listitem, lb);
}
fn gtkBind(arg_self: ?*c.GtkSignalListItemFactory, arg_listitem: ?*c.GtkListItem, arg_user_data: c.gpointer) callconv(.C) void {
    var self = arg_self;
    _ = @TypeOf(self);
    var listitem = arg_listitem;
    var user_data = arg_user_data;
    _ = @TypeOf(user_data);
    var lb: [*c]c.GtkWidget = c.gtk_list_item_get_child(listitem);
    var strobj: ?*c.GtkStringObject = @ptrCast(?*c.GtkStringObject, c.gtk_list_item_get_item(listitem));
    var text: [*c]const u8 = c.gtk_string_object_get_string(strobj);
    c.gtk_label_set_text(@ptrCast(?*c.GtkLabel, lb), text);
    c.gtk_label_set_attributes(@ptrCast(*c.GtkLabel, lb), description_attributes);
    c.gtk_widget_set_margin_top(lb, 5);
    c.gtk_widget_set_margin_end(lb, 17);
    c.gtk_widget_set_margin_start(lb, 17);
}

var current_label_widgets = std.ArrayList(*c.GtkWidget).init(allocator);

fn gtkActivateDictList(list: *c.GtkListView, position: u32, unused: c.gpointer) void {
    _ = unused;
    _ = list;

    dict_index = position;
    queryDictionary(current_phrase, dict_index) catch |err| @panic(@typeName(@TypeOf(err)));
    if (entry_index > current_entries.items.len)
        entry_index = current_entries.items.len;
    setEntry(entry_index) catch |err| @panic(@typeName(@TypeOf(err)));
}

fn setEntry(index: usize) !void {
    const entry = current_entries.items[index];

    while (current_label_widgets.items.len > 0) {
        var widget = current_label_widgets.pop();
        c.gtk_box_remove(@ptrCast(*c.GtkBox, description_widget), widget);
    }

    var i: u32 = 0;
    for (entry.descriptions.items) |description| {
        var name_string = @ptrCast([*c]const u8, entry.names.items[i]);
        var string = @ptrCast([*c]const u8, description);

        var name_widget = c.gtk_label_new(name_string);

        c.gtk_widget_set_valign(name_widget, c.GTK_ALIGN_START);
        c.gtk_widget_set_halign(name_widget, c.GTK_ALIGN_FILL);
        c.gtk_widget_set_hexpand(name_widget, 1);

        c.gtk_label_set_selectable(@ptrCast(*c.GtkLabel, name_widget), 1);
        c.gtk_label_set_xalign(@ptrCast(*c.GtkLabel, name_widget), 0.0);
        c.gtk_label_set_wrap(@ptrCast(*c.GtkLabel, name_widget), 1);
        c.gtk_label_set_attributes(@ptrCast(*c.GtkLabel, name_widget), name_attributes);

        gtkSetMargins(name_widget, 10);

        var label_widget = c.gtk_label_new(string);

        c.gtk_widget_set_valign(label_widget, c.GTK_ALIGN_START);
        c.gtk_widget_set_halign(label_widget, c.GTK_ALIGN_FILL);
        c.gtk_widget_set_hexpand(label_widget, 1);

        c.gtk_label_set_selectable(@ptrCast(*c.GtkLabel, label_widget), 1);
        c.gtk_label_set_xalign(@ptrCast(*c.GtkLabel, label_widget), 0.0);
        c.gtk_label_set_wrap(@ptrCast(*c.GtkLabel, label_widget), 1);
        c.gtk_label_set_attributes(@ptrCast(*c.GtkLabel, label_widget), description_attributes);

        gtkSetMargins(label_widget, 10);

        var separator_widget = c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL);

        try current_label_widgets.append(name_widget);
        try current_label_widgets.append(label_widget);
        try current_label_widgets.append(separator_widget);

        c.gtk_box_append(@ptrCast(*c.GtkBox, description_widget), name_widget);
        c.gtk_box_append(@ptrCast(*c.GtkBox, description_widget), label_widget);
        c.gtk_box_append(@ptrCast(*c.GtkBox, description_widget), separator_widget);
        i += 1;
    }
}

fn gtkActivateList(list: *c.GtkListView, position: u32, unused: c.gpointer) void {
    _ = unused;
    _ = list;
    entry_index = position;
    setEntry(entry_index) catch |err| @panic(@typeName(@TypeOf(err)));
}

pub const MecabError = error{
    MecabImproper,
    MecabNotEnoughFields,
};

fn queryDictionary(phrase: [*c]const u8, index: usize) !void {
    var argv_a = [_][*c]const u8{
        "mecab",
    };
    var cptr = @ptrCast([*c][*c]u8, &argv_a[0]);
    var mecab = c.mecab_new(argv_a.len, cptr);

    var c_response = c.mecab_sparse_tostr(mecab, phrase);
    std.log.info("mecab {s}", .{c_response});
    const type_ptr = @as([*:0]const u8, c_response);
    const ptr = std.mem.span(type_ptr);
    var line_iter = std.mem.split(u8, ptr, "\n");
    var string_array = std.ArrayList([*c]const u8).init(allocator);

    while (current_entries.items.len > 0) {
        const entry = current_entries.pop();
        for (entry.names.items) |name| {
            allocator.free(name);
        }
        for (entry.descriptions.items) |desc| {
            allocator.free(desc);
        }
        entry.descriptions.deinit();
        entry.names.deinit();
    }

    while (line_iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "EOS") or line.len == 0)
            continue;

        var field_iter = std.mem.split(u8, line, ",");
        var tab_iter = std.mem.split(u8, line, "\t");

        var i: u32 = 0;
        var name: []const u8 = undefined;
        if (tab_iter.next()) |word| {
            name = try toNullTerminated(word);
        } else {
            return MecabError.MecabNotEnoughFields;
        }
        var lemma: []const u8 = undefined;
        var no_field: bool = true;
        while (field_iter.next()) |field| {
            if (i == 6) {
                lemma = field;
                no_field = false;
                break;
            }
            i += 1;
        }
        if (no_field) {
            return MecabError.MecabNotEnoughFields;
        }
        std.log.info("lemma & name {s} {s}", .{ lemma, name });
        if (std.mem.startsWith(u8, lemma, "*"))
            lemma = name;

        if (library.len > 0) {
            var dict_union = library[index];

            switch (dict_union) {
                inline else => |*dict| {
                    const entry = try dict.getEntry(lemma, name);
                    try string_array.append(@ptrCast([*c]const u8, name));
                    try current_entries.append(entry);
                },
            }
        }
    }

    try string_array.append(null);

    var sl: ?*c.GtkStringList = c.gtk_string_list_new(@ptrCast([*c]const [*c]const u8, string_array.items));
    var ns: ?*c.GtkNoSelection = c.gtk_no_selection_new(@ptrCast(*c.GListModel, sl));

    _ = c.gtk_list_view_set_model(@ptrCast(*c.GtkListView, lv), @ptrCast(*c.GtkSelectionModel, ns));
    _ = c.gtk_list_view_set_single_click_activate(@ptrCast(*c.GtkListView, lv), 1);
    c.mecab_destroy(mecab);

    string_array.deinit();
}

fn gtkClicked(widget: *c.GtkWidget, data: c.gpointer) void {
    _ = widget;
    _ = data;
    current_phrase = c.gtk_entry_buffer_get_text(entry_buffer);
    queryDictionary(current_phrase, dict_index) catch |err| @panic(@typeName(@TypeOf(err)));
}

fn gtkActivate(app: *c.GtkApplication, user_data: c.gpointer) callconv(.C) void {
    _ = user_data;

    {
        description_attributes = c.pango_attr_list_new().?;
        var df = c.pango_font_description_new().?;
        c.pango_font_description_set_size(df, 14 * c.PANGO_SCALE);
        var attr = c.pango_attr_font_desc_new(df).?;
        c.pango_attr_list_insert(description_attributes, attr);
    }

    {
        name_attributes = c.pango_attr_list_new().?;
        var df = c.pango_font_description_new().?;
        c.pango_font_description_set_size(df, 21 * c.PANGO_SCALE);
        var attr = c.pango_attr_font_desc_new(df).?;
        c.pango_attr_list_insert(name_attributes, attr);
    }

    var window = c.gtk_application_window_new(app);
    c.gtk_window_set_title(@ptrCast(*c.GtkWindow, window), "土星辞書");
    c.gtk_window_set_default_size(@ptrCast(*c.GtkWindow, window), 200, 200);

    var dictionary_panel = c.gtk_paned_new(c.GTK_ORIENTATION_HORIZONTAL);

    c.gtk_window_set_child(@ptrCast(*c.GtkWindow, window), dictionary_panel);

    var dict_factory: ?*c.GtkListItemFactory = c.gtk_signal_list_item_factory_new();
    _ = c.g_signal_connect_data(dict_factory, "setup", @ptrCast(c.GCallback, &gtkSetup), null, null, 0);
    _ = c.g_signal_connect_data(dict_factory, "bind", @ptrCast(c.GCallback, &gtkBind), null, null, 0);

    dict_lv = c.gtk_list_view_new(null, dict_factory);
    _ = c.g_signal_connect_data(dict_lv, "activate", @ptrCast(c.GCallback, &gtkActivateDictList), null, null, 0);

    var dict_names = std.ArrayList([*c]const u8).init(allocator);

    for (library) |dict_union| {
        switch (dict_union) {
            inline else => |*dict| dict_names.append(@ptrCast([*c]const u8, dict.title)) catch |err| @panic(@typeName(@TypeOf(err))),
        }
    }

    dict_names.append(null) catch |err| @panic(@typeName(@TypeOf(err)));

    var sl: ?*c.GtkStringList = c.gtk_string_list_new(@ptrCast([*c]const [*c]const u8, dict_names.items));
    var ns: ?*c.GtkNoSelection = c.gtk_no_selection_new(@ptrCast(*c.GListModel, sl));

    _ = c.gtk_list_view_set_model(@ptrCast(*c.GtkListView, dict_lv), @ptrCast(*c.GtkSelectionModel, ns));
    _ = c.gtk_list_view_set_single_click_activate(@ptrCast(*c.GtkListView, dict_lv), 1);

    var dict_scroll = c.gtk_scrolled_window_new();
    c.gtk_scrolled_window_set_child(@ptrCast(*c.GtkScrolledWindow, dict_scroll), dict_lv);

    c.gtk_paned_set_start_child(@ptrCast(*c.GtkPaned, dictionary_panel), dict_scroll);

    gtkSetMargins(dict_scroll, 5);

    dict_names.deinit();

    // creating the vbox for the search bar and description
    var vbox = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    c.gtk_widget_set_halign(vbox, c.GTK_ALIGN_FILL);
    c.gtk_widget_set_valign(vbox, c.GTK_ALIGN_FILL);
    c.gtk_widget_set_hexpand(vbox, 1);
    c.gtk_widget_set_vexpand(vbox, 1);
    c.gtk_box_set_spacing(@ptrCast(*c.GtkBox, vbox), 20);

    c.gtk_paned_set_end_child(@ptrCast(*c.GtkPaned, dictionary_panel), vbox);

    // creating the hbox for the search box
    var hbox = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
    c.gtk_box_set_spacing(@ptrCast(*c.GtkBox, hbox), 10);
    c.gtk_widget_set_halign(hbox, c.GTK_ALIGN_FILL);
    c.gtk_widget_set_valign(hbox, c.GTK_ALIGN_START);
    c.gtk_widget_set_hexpand(hbox, 1);

    c.gtk_box_append(@ptrCast(*c.GtkBox, vbox), hbox);

    // creating the resulting words list view
    var words_factory: ?*c.GtkListItemFactory = c.gtk_signal_list_item_factory_new();
    _ = c.g_signal_connect_data(words_factory, "setup", @ptrCast(c.GCallback, &gtkSetup), null, null, 0);
    _ = c.g_signal_connect_data(words_factory, "bind", @ptrCast(c.GCallback, &gtkBind), null, null, 0);

    lv = c.gtk_list_view_new(null, words_factory);
    _ = c.g_signal_connect_data(lv, "activate", @ptrCast(c.GCallback, &gtkActivateList), null, null, 0);
    c.gtk_orientable_set_orientation(@ptrCast(*c.GtkOrientable, lv), c.GTK_ORIENTATION_HORIZONTAL);

    // creating window for the list
    var scrolled_window = c.gtk_scrolled_window_new();
    c.gtk_scrolled_window_set_child(@ptrCast(*c.GtkScrolledWindow, scrolled_window), lv);

    c.gtk_box_append(@ptrCast(*c.GtkBox, vbox), scrolled_window);

    // setting up the description widget
    description_widget = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    c.gtk_widget_set_halign(vbox, c.GTK_ALIGN_FILL);
    c.gtk_widget_set_hexpand(vbox, 1);
    c.gtk_widget_set_valign(vbox, c.GTK_ALIGN_FILL);
    c.gtk_widget_set_vexpand(vbox, 1);
    c.gtk_box_set_spacing(@ptrCast(*c.GtkBox, vbox), 20);
    gtkSetMargins(vbox, 20);

    // setting up scrolling for the description widget
    var description_scroll = c.gtk_scrolled_window_new();
    c.gtk_widget_set_valign(description_scroll, c.GTK_ALIGN_FILL);
    c.gtk_widget_set_vexpand(description_scroll, 1);

    c.gtk_scrolled_window_set_child(@ptrCast(*c.GtkScrolledWindow, description_scroll), description_widget);

    c.gtk_box_append(@ptrCast(*c.GtkBox, vbox), description_scroll);

    var button = c.gtk_button_new_with_label("Search");

    entry_buffer = c.gtk_entry_buffer_new(null, 0);
    c.gtk_entry_buffer_set_text(entry_buffer, message, message.len);
    var entry = c.gtk_entry_new_with_buffer(entry_buffer);
    c.gtk_widget_set_halign(entry, c.GTK_ALIGN_FILL);
    c.gtk_widget_set_hexpand(entry, 1);

    _ = c.g_signal_connect_data(button, "clicked", @ptrCast(c.GCallback, &gtkClicked), null, null, 0);

    c.gtk_box_append(@ptrCast(*c.GtkBox, hbox), entry);
    c.gtk_box_append(@ptrCast(*c.GtkBox, hbox), button);
    c.gtk_widget_show(window);
}

pub fn gtkStart(lib: []Dictionary) void {
    library = lib;
    var status: i32 = 0;

    const app = c.gtk_application_new("org.gtk.example", c.G_APPLICATION_FLAGS_NONE);
    _ = c.g_signal_connect_data(app, "activate", @ptrCast(c.GCallback, &gtkActivate), null, null, 0);
    status = c.g_application_run(@ptrCast(*c.GApplication, app), 0, null);
    c.g_object_unref(app);
}
