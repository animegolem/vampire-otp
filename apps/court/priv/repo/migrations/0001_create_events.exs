defmodule Court.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def up do
    create table(:events, primary_key: false) do
      add :event_seq, :integer, primary_key: true
      add :event_id, :string, null: false
      add :event_type, :string, null: false
      add :schema_version, :integer, null: false
      add :occurred_at, :utc_datetime_usec, null: false
      add :recorded_at, :utc_datetime_usec, null: false
      add :actor, :string, null: false
      add :causation_id, :string
      add :correlation_id, :string
      add :resident_id, :string, null: false
      add :incarnation_id, :string, null: false
      add :session_id, :string
      add :episode_id, :string
      add :segment_id, :string
      add :window_id, :string
      add :tick_id, :string
      add :turn_id, :string
      add :payload, :map, null: false, default: %{}
      add :artifact_refs, {:array, :string}, null: false, default: []
    end

    create unique_index(:events, [:event_id])
    create index(:events, [:event_type, :event_seq])
    create index(:events, [:resident_id, :event_seq])
    create index(:events, [:incarnation_id, :event_seq])

    execute("""
    CREATE TRIGGER events_reject_update
    BEFORE UPDATE ON events
    BEGIN
      SELECT RAISE(ABORT, 'court events are append-only: UPDATE rejected');
    END;
    """)

    execute("""
    CREATE TRIGGER events_reject_delete
    BEFORE DELETE ON events
    BEGIN
      SELECT RAISE(ABORT, 'court events are append-only: DELETE rejected');
    END;
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS events_reject_update")
    execute("DROP TRIGGER IF EXISTS events_reject_delete")
    drop table(:events)
  end
end
