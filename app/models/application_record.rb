class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  # Establish the reading role so connected_to(role: :reading) is available
  # to EventQuery / MetricQuery (sandbox Interaction roles) without adding
  # wrapper layers.  Normal writes still go to :primary; this declaration
  # only makes the reading connection pool reachable via connected_to.
  connects_to database: { writing: :primary, reading: :reading }
end
