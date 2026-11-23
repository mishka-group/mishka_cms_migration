# Ash in Mishka

Ash first: if Ash, AshPostgres, AshOban, Spark or Ash Signals already does a thing, use it. Read the guide in `deps/<pkg>/documentation` before using a feature you haven't used here. Copy the shape from the closest resource in mishka_cms_core or mishka_blog.

## Resources

- **Tenancy:** attribute multi-tenancy on `site_id` (`global? false`). A tenant create sets `site_id` from the tenant. See `mishka_cms_core/lib/mishka_cms_core/runtime/resources/redirect.ex` for the pattern.
- **Policies:**
  - `MishkaCmsCore.Accounts.Checks.AccessPermissions` with permission names `admin:dashboard:<area>` and `admin:api:<area>`.
  - Then `site_id == actor(:site_id)`, or the actor is a master.
  - `access_type :strict` where a refused read should error.
  - The extension's provisioning creates the permission names on install (core `Install.Bootstrap.ensure_permissions/1`, as `ExtensionProvision` does).
- **System actions:** actions only the system runs, such as a job's own steps, refuse every actor.
  - A job reaches them through AshOban's bypass (`AshOban.Checks.AshObanInteraction`).
  - `authorize?: false` is a documented exception for a true system lookup only, for example loading the actor before one exists. Say why in the `@moduledoc`.
- **Code interfaces live on the domain.** Callers use them, never `Ash.Changeset` plumbing scattered around.
- **Identities** enforce uniqueness in the database, partial ones too: `identity :one_active_per_site, [:site_id], where: expr(status in [:running])`. That beats checking in code or relying on job uniqueness.
- **State lifecycles are actions,** e.g. `:start`, `:finish`, `:fail`, `:cancel`, guarded by a validation on the status they move from.
- **Writes that belong together go in one transaction** (`Ash.transact/3`). Never write and then record separately.
- **Sensitive data:**
  - Mark it `sensitive?: true`, keep it private, and seal secrets with `Phoenix.Token.encrypt` the way core's `Settings` seals a `:secret` setting.
  - Clear it when it is no longer needed.
  - A `pub_sub` notifier `transform` strips it from broadcasts.
- **Timestamps:** `create_timestamp` / `update_timestamp`. A resource whose edits must be detected relies on `update_timestamp`, which is maintained by Ash and not writable.
- **Extra data:** `attribute :extra, :map` (core's name) holds key/value data the resource has no column for.
- **Migrations** come from `mix ash.codegen`. Check whether the repo commits or gitignores them, and follow it.

## guarded_struct inside the resource

From `mishka_cms_migration/lib/mishka_cms_migration/resources/migration_run.ex`:

```elixir
guardedstruct do
  auto_wire true

  field :source, :string,
    derives: "sanitize(trim, downcase) validate(string, not_empty, max_len=64)"

  sub_field :options, :map, authorized_fields: true do
    field :pages, :string,
      default: "draft",
      derives: "sanitize(trim) validate(enum=String[draft::publish])"

    field :comments, :boolean, default: false, derives: "validate(boolean)"
  end
end
```

`auto_wire` checks the action's input. A bad nested value comes back as an `Ash.Error.Invalid` with an `InvalidAttribute` at its field and path, and sub_field defaults are filled. Don't add a separate options module or a change to build the struct.

## Jobs: AshOban

Use AshOban triggers when they cover the needs:

- **Running the job:** `trigger :name` calls an Ash update action, with `transaction? false` for long work. `where expr(status == :running)` makes a cancelled or finished record skip its queued job.
- **Queueing:** `scheduler_cron false`, and queue from the starting action with `AshOban.run_trigger/3` in an `after_action`.
- **Failure and limits:** `max_attempts`, `backoff`, `timeout`, and `on_error :fail` (an update action that records the reason).
- **The actor:** an `AshOban.ActorPersister` stores and loads it, so the job writes as the user who started it.
- **A job killed at its timeout** can't run `on_error`. Catch that with a small Oban telemetry handler on `[:oban, :job, :exception]` with `state: :discard`.
- **Tests:** `use AshOban.Test`, `assert_triggered` and `perform_job`.

Fall back to plain Oban only for a part AshOban can't do, and say which.

## Signals

Ash 3.36 and later: `emit` on an action, `signals_in` on a listener. Use them when one of our resources must react to another's action inside the same transaction, and only where they replace hand-written code. Extension points for other extensions stay mishka_installer events, not signals.

## Progress and live updates

Save progress through an Ash action. The resource's `pub_sub` notifier broadcasts it, with sensitive fields stripped, and the LiveView subscribes to that topic. Don't add a hand-rolled PubSub module.

## Errors

Turn Ash errors into short, human messages, `field: message`, through `MishkaGervaz.Errors.translate_error/2`. Store only that message on a record a user will see, and keep the full error in the log.

## mishka_pay kinds (`MishkaPay.Ash.Resource`)

- A kind is for a row the provider knows: it needs `provider` and `provider_id`. A store's own row that starts as a draft (a catalog product) stays a plain resource, and the provider object (a price) points at it.
- A kind keeps the provider's ids as strings under plain names (`product_id` on a price, `coupon_id` on a promotion code, `customer_id` on a payment). The store's own link uses `store_<name>_id` (`belongs_to ... source_attribute :store_product_id`), never the kind's name, or the sync breaks.

- Every attribute of a kind is not writable (only the provider's sync forces them), so an action of the store that writes some takes them as arguments, and a change forces them in (`MyExtension.Resources.Changes.WriteArguments`).

- A row the store writes itself for a kind (not a provider sync) carries its `tenant` (`WriteArguments` option `tenant_into: :tenant`): the kind's later actions (`:archive`, `:refund`, `:resync`) read the provider with the keys of the site that row names, and a row without it fails with "no keys for tenant nil".
- A kind's own `:add` makes a provider object and a new row. To tie a row the store already has to the provider's object (a price made on a product page), call the SDK (`MishkaPay.create_price/1`) and give the same row the provider's ids with an update action of the store, so the row keeps its id and its place.

## Counters, limits and claims

A limit or a count (downloads against a limit, "only the first caller delivers") is one atomic update: `Ash.bulk_update(query, :action, input, strategy: :atomic, return_records?: true)` over a query whose filter holds the whole rule, and an action with `atomic_update(:count, expr(count + 1))`. The database serializes two updates of one row and the second re-reads it, so nothing sits between a read and a write. Count the records the update returned; none means the rule refused, and a read afterwards says why.

`Ash.transact/3` wraps what its function returns once more (`{:ok, {:ok, x}}`) and turns an `{:error, reason}` into an Ash error. To return the reasons of a refusal, return them as plain values from the function (`{:refused, :limit}`) and unwrap them after.

## Tenants and links

- **`site_id` comes from the tenant and is never input.** Make the `site_id` attribute private (`attribute_public? false` on the `site` belongs_to) and put the multitenancy block and that relationship in the one fragment macro every resource uses (`MyExtension.Resources.Policies`). Ash then writes `site_id` from `tenant:` on create. A public `site_id` is accepted by `create: :*` and fails a tenant create with "attribute site_id is required".
- **A foreign key does not prove the same tenant.** A create that takes the id of another row (`product_id`, `store_product_id`) checks it with a validation that reads the target inside the call's tenant (`MyExtension.Resources.Validations.SameSite`), so another site's row is "not found".
- **`Ash.exists?/2` raises on a forbidden read.** In a validation or a check use `Ash.exists/2`, which returns `{:error, error}` to hand back.

## State machines (AshStateMachine)

- Every transition needs an action of that name, or AshStateMachine refuses it: write the transition actions (`:publish`, `:archive`, `:approve`) with the machine.
- The primary create and update list their accepted fields and leave the state out, so a state only moves through its transitions.
- A row whose state comes from a provider (a payment, a subscription) has no state machine: events arrive out of order, and the provider's word is written as it is.

## Oban in an extension

The host starts Oban (`AshOban.config/2` over its `:ash_domains`), and core's test boot does it in tests. An extension only names its queues in config and never starts Oban itself.

## Anti-patterns to avoid

- Writing through `Repo` around an Ash action.
- `authorize?: false` to dodge a policy.
- Read-then-write without a transaction or an identity.
- Re-implementing what an Ash type, change, validation or extension already provides.
- Uniqueness or state checks in code that the database could enforce.

## Database rules in the resource

- **Every foreign key leads an index.** AshPostgres prefixes a multi-tenant `custom_indexes` entry with `site_id`, which a foreign key check (`WHERE order_id = $1`) cannot use: write the key's own index with `all_tenants?: true` (partial `where: "fk IS NOT NULL"` for a nullable key). Without it each deleted parent reads the whole child table.
- **A rule a row must hold is a `check_constraint`** with a plain `message:`; Ash returns it on the attribute. Seed data in tests must hold it too.
- **An append-only table is a trigger in `custom_statements`** that raises `check_violation` with `CONSTRAINT = '<name>'`, and a `check_constraint :attr, "<name>", message: "..."` with no `check:` maps it to a plain sentence. Let a foreign key's own cascade through (`pg_trigger_depth() > 1`), and give a legitimate path (an erasure) a transaction-local flag (`set_config('<app>.<flag>', 'on', true)`), compared with `IS DISTINCT FROM 'on'` so an unset flag refuses.
- **PaperTrail on a hard-deleted resource:** `create_version_on_destroy? false` (the version's key to the deleted row fails), `sensitive_attributes :ignore`, and `store_action_inputs? false` when an action takes a `:term` argument. An atomic update writes a version each time it runs.
- **A bypass of a buyer's own rows** is added to every query of the resource, admins' too: give it a condition that only the buyer meets, or a site's counts cannot come from an index.
