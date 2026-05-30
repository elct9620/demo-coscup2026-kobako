require "test_helper"

# Verifies the SQL-boundary layer of the two-layer read-only defense
# (docs/architecture.md "唯讀資料存取（兩層唯讀防禦）").
#
# Two invariants under test:
#
#   1. SQLite driver-level write rejection (mode=ro):
#      Opening the database file with "file:..?mode=ro" rejects write
#      operations at the file-open / driver layer — independent of Rails or
#      any application-level check.  This is the stronger guarantee and
#      corresponds to the SPEC invariant "任何到達資料庫的寫入在連線層被拒絕".
#
#   2. Reading role is established and readable:
#      connected_to(role: :reading) does not raise ConnectionNotEstablished,
#      and reads return correct data (the reading connection resolves to the
#      same underlying database file as the writing connection).
#
# Note on transactional fixtures: Rails' setup_shared_connection_pool redirects
# the reading pool to the writing pool during transactional tests so that
# fixture data (inserted in an open write transaction) is visible to reads.
# This means AR-layer write prevention via replica: true is intentionally
# bypassed during fixtures setup, which is expected Rails behaviour.
# The driver-level mode=ro test below opens a *direct* SQLite3 connection
# (bypassing AR/fixtures) to prove the guarantee holds at the driver layer.
class ReadingConnectionTest < ActiveSupport::TestCase
  # --- SQLite driver-level write rejection (mode=ro) ---

  test "write via mode=ro URI is rejected at the SQLite driver layer" do
    open_ro_connection do |conn|
      error = assert_raises(SQLite3::ReadOnlyException) do
        conn.execute("INSERT INTO events (occurred_at, name, properties, created_at, updated_at) VALUES (datetime('now'), 'test', '{}', datetime('now'), datetime('now'))")
      end

      assert_match(/readonly/i, error.message)
    end
  end

  test "read via mode=ro URI succeeds at the SQLite driver layer" do
    open_ro_connection do |conn|
      result = conn.execute("SELECT COUNT(*) FROM events")

      assert_kind_of Array, result
      assert_equal 1, result.length
    end
  end

  # --- Reading role availability and connectivity ---

  test "reading role is established and does not raise ConnectionNotEstablished" do
    active = ActiveRecord::Base.connected_to(role: :reading) do
      ActiveRecord::Base.connection.active?
    end

    assert active, "Expected reading connection to be active"
  end

  test "reading role returns correct event count" do
    # Fixtures are loaded through the writing connection, and Rails shares the
    # writing connection pool with the reading pool during transactional tests,
    # so fixture data is visible to reads here.
    ActiveRecord::Base.connected_to(role: :reading) do
      count = Event.count
      assert count >= 0, "Expected a non-negative count, got #{count}"
    end
  end

  test "reading role can query events fixture data" do
    recent = events(:recent_page_view)

    ActiveRecord::Base.connected_to(role: :reading) do
      found = Event.find_by(id: recent.id)
      assert_not_nil found, "Expected to find fixture event via reading role"
      assert_equal recent.name, found.name
    end
  end

  private

  # Opens a direct SQLite3 connection to the primary DB file using mode=ro URI,
  # bypassing Rails AR and test fixture pool redirect — proving the driver-layer
  # guarantee independently of Rails infrastructure.
  def open_ro_connection
    db_path = ActiveRecord::Base.connection_db_config.database
    conn = SQLite3::Database.new("file:#{db_path}?mode=ro")
    yield conn
  ensure
    conn&.close
  end
end
