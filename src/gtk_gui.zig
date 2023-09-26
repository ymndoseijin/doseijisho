const std = @import("std");
const unicode = @import("std").unicode;
const defs = @import("defs.zig");

const stdout = defs.stdout;

const Library = defs.Library;
const Entry = defs.Entry;
const c = defs.c;
const allocator = defs.allocator;
const toNullTerminated = defs.toNullTerminated;
const message = defs.message;
const Dictionary = defs.Dictionary;

var current_entries = std.ArrayList(defs.QueryResult).init(allocator);

var entry_buffer: *c.GtkEntryBuffer = undefined;
var description_widget: *c.GtkWidget = undefined;
var lv: [*c]c.GtkWidget = undefined;
var dict_lv: [*c]c.GtkWidget = undefined;
var description_attributes: *c.PangoAttrList = undefined;
var name_attributes: *c.PangoAttrList = undefined;

var library: Library = undefined;

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

// setup the dictionary list
fn gtkSetup(_: ?*c.GtkListItemFactory, list_item: ?*c.GtkListItem, _: c.gpointer) callconv(.C) void {
    var lb: [*c]c.GtkWidget = c.gtk_label_new(null);
    c.gtk_list_item_set_child(list_item, lb);
}

// bind the dictionary list
fn gtkBind(_: ?*c.GtkSignalListItemFactory, list_item: ?*c.GtkListItem, _: c.gpointer) callconv(.C) void {
    var lb: [*c]c.GtkWidget = c.gtk_list_item_get_child(list_item);
    var strobj: ?*c.GtkStringObject = @ptrCast(c.gtk_list_item_get_item(list_item));
    var text: [*c]const u8 = c.gtk_string_object_get_string(strobj);

    c.gtk_label_set_text(@ptrCast(lb), text);
    c.gtk_label_set_attributes(@ptrCast(lb), description_attributes);
    c.gtk_label_set_wrap(@ptrCast(lb), 1);
    c.gtk_widget_set_margin_top(lb, 5);
    c.gtk_widget_set_margin_end(lb, 17);
    c.gtk_widget_set_margin_start(lb, 17);
}

var current_label_widgets = std.ArrayList(*c.GtkWidget).init(allocator);

fn gtkActivateDictList(_: *c.GtkListView, position: u32, _: c.gpointer) callconv(.C) void {
    dict_index = position;
    if (library.dicts.len > 0) {
        queryDictionary(current_phrase, dict_index) catch |err| @panic(@typeName(@TypeOf(err)));
        setEntry(entry_index) catch |err| @panic(@typeName(@TypeOf(err)));
    }
}

fn setEntry(in_index: usize) !void {
    var index = in_index;
    if (index > current_entries.items.len - 1)
        index = current_entries.items.len - 1;
    const query = current_entries.items[index];

    while (current_label_widgets.items.len > 0) {
        var widget = current_label_widgets.pop();
        c.gtk_box_remove(@ptrCast(description_widget), widget);
    }

    const result_query = query.entries orelse return;

    for (result_query.entries.items) |entry| {
        var description = entry.description;
        var name_string = entry.name;
        var string = description;

        var name_widget = c.gtk_label_new(name_string);
        var name_label: ?*c.GtkLabel = @ptrCast(name_widget);

        c.gtk_widget_set_valign(name_widget, c.GTK_ALIGN_START);
        c.gtk_widget_set_halign(name_widget, c.GTK_ALIGN_FILL);
        c.gtk_widget_set_hexpand(name_widget, 1);

        c.gtk_label_set_selectable(name_label, 1);
        c.gtk_label_set_xalign(name_label, 0.0);
        c.gtk_label_set_wrap(name_label, 1);
        c.gtk_label_set_attributes(name_label, name_attributes);

        gtkSetMargins(name_widget, 10);

        var string_widget = c.gtk_label_new(string);
        var string_label: ?*c.GtkLabel = @ptrCast(string_widget);

        c.gtk_widget_set_valign(string_widget, c.GTK_ALIGN_START);
        c.gtk_widget_set_halign(string_widget, c.GTK_ALIGN_FILL);
        c.gtk_widget_set_hexpand(string_widget, 1);

        c.gtk_label_set_selectable(string_label, 1);
        c.gtk_label_set_xalign(string_label, 0.0);
        c.gtk_label_set_wrap(string_label, 1);
        c.gtk_label_set_attributes(string_label, description_attributes);

        gtkSetMargins(string_widget, 10);

        var separator_widget = c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL);

        try current_label_widgets.append(name_widget);
        try current_label_widgets.append(string_widget);
        try current_label_widgets.append(separator_widget);

        c.gtk_box_append(@ptrCast(description_widget), name_widget);
        c.gtk_box_append(@ptrCast(description_widget), string_widget);
        c.gtk_box_append(@ptrCast(description_widget), separator_widget);
    }
}

fn gtkActivateList(list: *c.GtkListView, position: u32, unused: c.gpointer) callconv(.C) void {
    _ = unused;
    _ = list;
    entry_index = position;
    setEntry(entry_index) catch |err| @panic(@typeName(@TypeOf(err)));
}
fn queryDictionary(phrase: [*c]const u8, index: usize) !void {
    var string_array = std.ArrayList([*c]const u8).init(allocator);
    defer string_array.deinit();

    for (current_entries.items) |query| query.deinit();

    current_entries.deinit();
    current_entries = try library.queryLibrary(phrase, index);

    for (current_entries.items) |query| {
        try string_array.append(@ptrCast(query.query_name));
    }

    try string_array.append(null);

    var sl: ?*c.GtkStringList = c.gtk_string_list_new(@ptrCast(string_array.items));
    var ns: ?*c.GtkNoSelection = c.gtk_no_selection_new(@ptrCast(sl));

    _ = c.gtk_list_view_set_model(@ptrCast(lv), @ptrCast(ns));
    _ = c.gtk_list_view_set_single_click_activate(@ptrCast(lv), 1);
}

fn gtkClicked(widget: *c.GtkWidget, data: c.gpointer) callconv(.C) void {
    _ = widget;
    _ = data;
    entry_index = 0;
    current_phrase = c.gtk_entry_buffer_get_text(entry_buffer);
    if (library.dicts.len > 0) {
        queryDictionary(current_phrase, dict_index) catch |err| @panic(@typeName(@TypeOf(err)));
        setEntry(entry_index) catch |err| @panic(@typeName(@TypeOf(err)));
    }
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
    c.gtk_window_set_title(@ptrCast(window), "土星辞書");
    c.gtk_window_set_default_size(@ptrCast(window), 200, 200);

    var dictionary_panel = c.gtk_paned_new(c.GTK_ORIENTATION_HORIZONTAL);

    c.gtk_window_set_child(@ptrCast(window), dictionary_panel);

    var dict_factory: ?*c.GtkListItemFactory = c.gtk_signal_list_item_factory_new();
    _ = c.g_signal_connect_data(dict_factory, "setup", @ptrCast(&gtkSetup), null, null, 0);
    _ = c.g_signal_connect_data(dict_factory, "bind", @ptrCast(&gtkBind), null, null, 0);

    dict_lv = c.gtk_list_view_new(null, dict_factory);
    _ = c.g_signal_connect_data(dict_lv, "activate", @ptrCast(&gtkActivateDictList), null, null, 0);

    var dict_names = std.ArrayList([*c]const u8).init(allocator);

    for (library.dicts) |dict_union| {
        switch (dict_union) {
            inline else => |*dict| dict_names.append(@ptrCast(dict.title)) catch |err| @panic(@typeName(@TypeOf(err))),
        }
    }

    dict_names.append(null) catch |err| @panic(@typeName(@TypeOf(err)));

    var sl: ?*c.GtkStringList = c.gtk_string_list_new(@ptrCast(dict_names.items));
    var ns: ?*c.GtkNoSelection = c.gtk_no_selection_new(@ptrCast(sl));

    _ = c.gtk_list_view_set_model(@ptrCast(dict_lv), @ptrCast(ns));
    _ = c.gtk_list_view_set_single_click_activate(@ptrCast(dict_lv), 1);

    var dict_scroll = c.gtk_scrolled_window_new();
    c.gtk_scrolled_window_set_child(@ptrCast(dict_scroll), dict_lv);

    c.gtk_paned_set_start_child(@ptrCast(dictionary_panel), dict_scroll);

    gtkSetMargins(dict_scroll, 5);

    dict_names.deinit();

    // creating the vbox for the search bar and description
    var vbox = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    c.gtk_widget_set_halign(vbox, c.GTK_ALIGN_FILL);
    c.gtk_widget_set_valign(vbox, c.GTK_ALIGN_FILL);
    c.gtk_widget_set_hexpand(vbox, 1);
    c.gtk_widget_set_vexpand(vbox, 1);
    c.gtk_box_set_spacing(@ptrCast(vbox), 20);

    c.gtk_paned_set_end_child(@ptrCast(dictionary_panel), vbox);

    // creating the hbox for the search box
    var hbox = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
    c.gtk_box_set_spacing(@ptrCast(hbox), 10);
    c.gtk_widget_set_halign(hbox, c.GTK_ALIGN_FILL);
    c.gtk_widget_set_valign(hbox, c.GTK_ALIGN_START);
    c.gtk_widget_set_hexpand(hbox, 1);

    c.gtk_box_append(@ptrCast(vbox), hbox);

    // creating the resulting words list view
    var words_factory: ?*c.GtkListItemFactory = c.gtk_signal_list_item_factory_new();
    _ = c.g_signal_connect_data(words_factory, "setup", @ptrCast(&gtkSetup), null, null, 0);
    _ = c.g_signal_connect_data(words_factory, "bind", @ptrCast(&gtkBind), null, null, 0);

    lv = c.gtk_list_view_new(null, words_factory);
    _ = c.g_signal_connect_data(lv, "activate", @ptrCast(&gtkActivateList), null, null, 0);
    c.gtk_orientable_set_orientation(@ptrCast(lv), c.GTK_ORIENTATION_HORIZONTAL);

    // creating window for the list
    var scrolled_window = c.gtk_scrolled_window_new();
    c.gtk_scrolled_window_set_child(@ptrCast(scrolled_window), lv);
    c.gtk_scrolled_window_set_overlay_scrolling(@ptrCast(scrolled_window), 0);
    c.gtk_widget_set_size_request(scrolled_window, -1, 70);

    c.gtk_box_append(@ptrCast(vbox), scrolled_window);

    // setting up the description widget
    description_widget = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    c.gtk_widget_set_halign(vbox, c.GTK_ALIGN_FILL);
    c.gtk_widget_set_hexpand(vbox, 1);
    c.gtk_widget_set_valign(vbox, c.GTK_ALIGN_FILL);
    c.gtk_widget_set_vexpand(vbox, 1);
    c.gtk_box_set_spacing(@ptrCast(vbox), 20);
    gtkSetMargins(vbox, 20);

    // setting up scrolling for the description widget
    var description_scroll = c.gtk_scrolled_window_new();
    c.gtk_widget_set_valign(description_scroll, c.GTK_ALIGN_FILL);
    c.gtk_widget_set_vexpand(description_scroll, 1);

    c.gtk_scrolled_window_set_child(@ptrCast(description_scroll), description_widget);

    c.gtk_box_append(@ptrCast(vbox), description_scroll);

    var button = c.gtk_button_new_with_label("Search");

    entry_buffer = c.gtk_entry_buffer_new(null, 0);
    c.gtk_entry_buffer_set_text(entry_buffer, message, message.len);
    var entry = c.gtk_entry_new_with_buffer(entry_buffer);
    c.gtk_widget_set_halign(entry, c.GTK_ALIGN_FILL);
    c.gtk_widget_set_hexpand(entry, 1);

    _ = c.g_signal_connect_data(entry, "activate", @ptrCast(&gtkClicked), null, null, 0);
    _ = c.g_signal_connect_data(button, "clicked", @ptrCast(&gtkClicked), null, null, 0);

    c.gtk_box_append(@ptrCast(hbox), entry);
    c.gtk_box_append(@ptrCast(hbox), button);
    c.gtk_widget_show(window);
}

pub fn gtkStart(lib: Library) void {
    library = lib;
    var status: i32 = 0;

    const app = c.gtk_application_new("me.doseijin.doseijisho", c.G_APPLICATION_FLAGS_NONE);
    _ = c.g_signal_connect_data(app, "activate", @ptrCast(&gtkActivate), null, null, 0);
    status = c.g_application_run(@ptrCast(app), 0, null);
    c.g_object_unref(app);

    for (current_entries.items) |query| query.deinit();
    current_entries.deinit();
    current_label_widgets.deinit();
}
