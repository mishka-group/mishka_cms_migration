# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(MishkaBlog.Comment) do
  defmodule MishkaCmsMigration.Targets.BlogComment do
    @moduledoc """
    The `"comment"` items of a source written as the Blog's comments (`MishkaBlog.Comment`),
    through the `:create` and `:update` an admin's own comment form runs, on the run's site and as
    the admin who pressed Import: the admin needs the Blog's `admin:dashboard:blog:comment` to write
    them and `admin:dashboard:blog:post` to find the posts and bloggers they belong to, and the
    Blog's own rules decide the rest, such as how a comment's text is cleaned (it is plain text).
    The Blog's `:create` keeps the author it is given (`author_id`), or a guest's name, instead of
    making the acting admin the author.

    An item's content is the comment's text, with its tags taken out and its entities read
    (`MishkaCmsCore.PlainText.from_html/1`), as the Blog stores a comment. Its `"status"` is the
    comment's: `"approved"` is approved and `"hold"` (held for moderation) is pending. The Blog
    sets when a comment is created, so a comment is dated the day it is imported, not the day it
    was written. The commenter's IP address and browser are not copied into the comment; they stay
    in the item's `extra`.

    ## Which comments

    By the run's `comments` choice (`MishkaCmsMigration.MigrationRun`'s options), read with
    `existing/2` before anything is written, in the dry run too:

      * off (the default) — every item is skipped as `"not_chosen"`, and nothing is written;
      * on — a comment is written, except:
        * one that is not a comment, a pingback or a trackback (`"type"`) — skipped as
          `"not_a_comment"`;
        * one that is not approved or held (`"status"`), such as spam or in the trash — skipped as
          `"spam_or_trash"`;
        * one on a page (`"post_type"`), which the Blog has no place for — skipped as
          `"page_comment"`;
        * in an import, one whose post has no Blog post, because it failed, was never written or
          an admin left it out — skipped as `"post_missing"`, as is a reply whose parent comment
          was not written (the walk's `"parent_missing"`) or was left out (`"parent_left_out"`).

    A dry run writes no post, so it does not look for one: an item it plans may still be skipped
    for its post when the import runs.

    ## Whose comment

    The comment's author is a user of the run's site, found in this order:

      * the user whose blogger profile the same run, or an earlier one, wrote or connected for the
        comment's `"author"`, the source's user (`MishkaCmsMigration.Targets.BlogBlogger`);
      * the user whose email is the comment's `"author_email"`, among the users of the run's site
        (`MishkaCmsMigration.Targets.BlogBlogger.users/2`), so the admin needs the core's
        `admin:dashboard:user` to find any.

    A comment with neither is a guest's: it is written with the name and email the commenter gave
    (`guest_name`, `guest_email`) and no author. A guest who gave no name is written as
    `"Anonymous"`, the name WordPress shows for one. An email the Blog would refuse is left out of
    the comment instead of failing it, and the report says so (`"guest_email_dropped"`).

    The report says a guest's comment is one (`"guest_comment: <name>"`, which
    `MishkaCmsMigration.Report` counts as `guests`). The authors of a page's comments, and in an
    import the posts they are on, are found together in `existing/2`, one read for the page in a
    dry run and in an import, from the comments as the source lists them, and handed to each
    comment's note and write as its context's `prepared` (`{:created, prepared}`). A dry run writes
    no blogger, so it finds the authors from the users the site has, and plans a comment by a
    source's user as a user's when the run's `authors` choice is `"create"`, which makes every such
    user.

    ## Its post and its place in a thread

    The comment is written on the Blog post the same run, or an earlier one, wrote for its
    `"post"` (`MishkaCmsMigration.Targets.BlogPost`), under the comment written for its parent: the
    walk writes a parent first. Its post, parent and author are set when the comment is created and
    never changed by a later run, which writes its text and status over a comment it wrote. Its post
    is what it needs (`needs/1`), so Import this item writes a comment alone only on a post an
    import wrote.

    A re-run is held to the rules every target is: a comment WordPress did not change is
    `"unchanged"`, and one an admin edited or moderated in the CMS is kept as the admin left it
    (`MishkaCmsMigration.Workers.Helpers.Decision`). 

    Defined only where Mishka Blog is loaded, and supervised by `MishkaCmsMigration.Application`
    only then; on a node without the Blog its items wait for it (`"blog_missing"`).
    """

    use MishkaCmsMigration.Target,
      kind: "comment",
      resource: MishkaBlog.Comment,
      create: :create,
      update: :update

    alias MishkaBlog.{Blogger, BlogPost, Comment}
    alias MishkaCmsCore.Accounts.User
    alias MishkaCmsCore.Accounts.Validations.ValidEmail
    alias MishkaCmsCore.PlainText
    alias MishkaCmsMigration.Source.Item
    alias MishkaCmsMigration.Targets.BlogBlogger
    alias MishkaCmsMigration.Targets.Helpers.Written

    @anonymous "Anonymous"
    @statuses %{"approved" => :approved, "hold" => :pending}

    @impl MishkaCmsMigration.Target
    def existing(items, %{options: %{comments: false}}),
      do: Map.new(items, &{&1.source_id, {:skipped, "not_chosen"}})

    def existing(items, context) do
      written = Enum.reject(items, &left_out/1)
      page = %{posts: posts(written, context), authors: authors(written, context)}

      Map.new(items, &{&1.source_id, left_out(&1) || found(&1, page, context)})
    end

    @impl MishkaCmsMigration.Target
    def needs(%Item{attrs: %{"post_type" => "page"}}), do: %{}

    def needs(%Item{attrs: %{"post" => post}}) when is_integer(post) or is_binary(post),
      do: %{"post" => [to_string(post)]}

    def needs(_item), do: %{}

    @impl MishkaCmsMigration.Target
    def attrs(item, %{record: nil, prepared: %{post_id: post, author_id: author}} = context) do
      item
      |> comment()
      |> Map.merge(%{post_id: post, parent_comment_id: context.parent_id})
      |> Map.merge(writer(item, author))
    end

    def attrs(item, _update), do: comment(item)

    @impl MishkaCmsMigration.Target
    def note(
          %Item{attrs: %{"author" => author}},
          %{record: nil, mode: :dry_run, options: %{authors: "create"}}
        )
        when is_integer(author) and author > 0,
        do: nil

    def note(item, %{record: nil, prepared: %{author_id: author}}), do: noted(item, author)

    def note(_item, %{record: %{guest_name: name}}) when is_binary(name),
      do: "guest_comment: " <> name

    def note(_item, _context), do: nil

    defp comment(%Item{attrs: %{"status" => status}} = item),
      do: %{
        content: item |> Item.html() |> PlainText.from_html(),
        status: Map.fetch!(@statuses, status)
      }

    defp found(item, %{posts: posts, authors: authors}, context),
      do:
        unwritten(item, posts, context) ||
          {:created, %{post_id: posts[post_key(item)], author_id: authors[item.source_id]}}

    defp left_out(%Item{attrs: %{"type" => type}}) when type != "comment",
      do: {:skipped, "not_a_comment"}

    defp left_out(%Item{attrs: %{"status" => status}}) when not is_map_key(@statuses, status),
      do: {:skipped, "spam_or_trash"}

    defp left_out(%Item{attrs: %{"post_type" => "page"}}), do: {:skipped, "page_comment"}
    defp left_out(_item), do: nil

    defp unwritten(_item, _posts, %{mode: :dry_run}), do: nil

    defp unwritten(item, posts, _context),
      do: posts |> Map.get(post_key(item)) |> missing()

    defp missing(nil), do: {:skipped, "post_missing"}
    defp missing(_post), do: nil

    defp authors(items, context) do
      bloggers = Written.call(Blogger, "user", sources(items), context)
      users = items |> Enum.flat_map(&email/1) |> BlogBlogger.users(context)

      for item <- items,
          id = author_id(item, bloggers, users),
          into: %{},
          do: {item.source_id, id}
    end

    defp author_id(%Item{attrs: attrs}, bloggers, users) do
      case {bloggers[to_string(attrs["author"])], users[address(attrs)]} do
        {%Blogger{user_id: id}, _user} -> id
        {nil, %User{id: id}} -> id
        {nil, nil} -> nil
      end
    end

    defp sources(items),
      do: for(%Item{attrs: %{"author" => id}} <- items, is_integer(id) and id > 0, do: id)

    defp email(%Item{attrs: attrs}), do: attrs |> address() |> List.wrap()

    defp writer(_item, author) when is_binary(author), do: %{author_id: author}
    defp writer(item, nil), do: item |> guest() |> Map.fetch!(:attrs)

    defp noted(_item, author) when is_binary(author), do: nil

    defp noted(item, nil) do
      %{name: name, dropped: dropped} = guest(item)
      Enum.join(["guest_comment: " <> name | dropped], "; ")
    end

    # What a guest gave, as the Blog keeps it: an email it would refuse is left out, and `dropped`
    # says so.
    defp guest(%Item{attrs: attrs}) do
      name = attrs |> text("author_name") |> Kernel.||(@anonymous) |> String.slice(0, 255)
      {email, lost_email} = checked(text(attrs, "author_email"), &email?/1, "guest_email_dropped")

      %{
        name: name,
        dropped: lost_email,
        attrs:
          %{guest_name: name, guest_email: email}
          |> Map.reject(fn {_field, value} -> is_nil(value) end)
      }
    end

    defp text(attrs, key), do: attrs |> Map.get(key) |> trimmed()

    defp trimmed(value) when is_binary(value), do: value |> String.trim() |> filled()
    defp trimmed(_value), do: nil

    defp filled(""), do: nil
    defp filled(value), do: value

    defp checked(nil, _valid?, _code), do: {nil, []}

    defp checked(value, valid?, code),
      do: if(valid?.(value), do: {value, []}, else: {nil, [code]})

    defp email?(email) do
      Comment
      |> Ash.Changeset.new()
      |> Ash.Changeset.force_change_attribute(:guest_email, email)
      |> ValidEmail.validate([field: :guest_email], %{}) == :ok
    end

    defp address(%{"author_email" => email}) when is_binary(email) and email != "",
      do: String.downcase(email)

    defp address(_attrs), do: nil

    defp posts(_items, %{mode: :dry_run}), do: %{}

    defp posts(items, context) do
      BlogPost
      |> Written.call("post", Enum.map(items, &post_key/1), context)
      |> Map.new(fn {key, post} -> {key, post.id} end)
    end

    defp post_key(%Item{attrs: %{"post" => post}}), do: to_string(post)
  end
end
