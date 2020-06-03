# frozen_string_literal: true

# Haplo Platform                                    https://haplo.org
# (c) Haplo Services Ltd 2006 - 2020            https://www.haplo.com
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

class MiniORM::Record
  def self.table(name)
    t = MiniORM::Table.new(name)
    yield t
    self.const_set(:TABLE, t)
    t._setup_record_class(self)
  end

  # -------------------------------------------------------------------------

  # Callbacks - override in derived classes
  def before_save; end
  def after_create; end
  def after_update; end
  def after_save; end
  def after_delete; end

  # -------------------------------------------------------------------------

  def save
    before_save()
    @id.nil? ? _create() : _update()
    after_save()
    @_dirty_values = nil
    self
  end

  def persisted?
    @id != nil
  end

  def changed?
    @id.nil? || (@_dirty_values != nil)
  end

  def attribute_changed?(attribute)
    (@_dirty_values != nil) && @_dirty_values.has_key?(attribute)
  end

  def changed_attributes
    (@_dirty_values || {}).dup
  end

  def delete
    raise MiniORM::MiniORMException, "Row has not been committed to database" if @id.nil?
    KApp.with_jdbc_database do |db|
      statement = db.prepareStatement(self.class._sql_fragment(:DELETE_RECORD_SQL))
      statement.setInt(1, @id)
      begin
        statement.execute()
      ensure
        statement.close()
      end
    end
    KApp.logger.info("DB #{self.class.name}: DELETE row id #{@id}")
    after_delete() # but before values & id are wiped
    self._assign_all_values(*([nil] * self.method(:_assign_all_values).arity))
    @id = nil
    self
  end

  def self.read(id)
    unless id.kind_of?(Integer) && id > 0
      raise MiniORM::MiniORMException, "Bad record ID"
    end
    self.new._read(id)
  end

  # Query class and self.where() methods generated by Table

  # -------------------------------------------------------------------------

  def _read(id)
    table = self._table
    KApp.with_jdbc_database do |db|
      statement = db.prepareStatement(self.class._sql_fragment(:READ_SQL))
      statement.setInt(1, id)
      begin
        results = statement.executeQuery()
        raise MiniORM::MiniORMRecordNotFoundException, "#{self.class.name} id #{id} does not exist" unless results.next()
        _assign_values_from_results(table, id, results)
      ensure
        statement.close()
      end
    end
  end

  def _assign_values_from_results(table, id, results)
    values = []
    table.columns.each_with_index do |c, index|
      value = c.get_value_from_resultset(results, index+1)
      value = nil if c.nullable && results.wasNull()
      values << value
    end
    self._assign_all_values(*values)
    @id = id
    self
  end

  def _with_write_statement_for_dirty_values
    table = self._table
    dirty_columns = table.columns.select do |c|
      @_dirty_values.has_key?(c.name)
    end
    sql = yield table, nil, dirty_columns
    KApp.with_jdbc_database do |db|
      statement = db.prepareStatement(sql)
      begin
        dirty_columns.each_with_index do |c, index|
          value = @_dirty_values[c.name]
          if value.nil?
            statement.setNull(index+1, c.sqltype)
          else
            c.set_value_in_statement(statement, index+1, value)
          end
        end
        yield table, statement, dirty_columns
      ensure
        statement.close()
      end
    end
  end

  def _create
    raise MiniORM::MiniORMException, "No values set when creating #{_table.name}" if @_dirty_values.nil?
    _with_write_statement_for_dirty_values do |table, statement, dirty_columns|
      unless statement
        "INSERT INTO #{self.class.db_schema_name}.#{table.name_str}(#{dirty_columns.map{|c|c.db_name_str}.join(',')}) VALUES (#{Array.new(dirty_columns.length,'?').join(',')}) RETURNING id"
      else
        results = statement.executeQuery()
        raise MiniORMException, "INSERT didn't return an ID" unless results.next()
        @id = results.getInt(1)
      end
    end
    KApp.logger.info("DB #{self.class.name}: INSERT row id #{@id}")
    after_create()
  end

  def _update
    return if @_dirty_values.nil? # null op
    _with_write_statement_for_dirty_values do |table, statement, dirty_columns|
      unless statement
        "UPDATE #{self.class.db_schema_name}.#{table.name_str} SET #{dirty_columns.map{|c|"#{c.db_name_str}=?"}.join(',')} WHERE id=?"
      else
        statement.setInt(dirty_columns.length+1, @id)
        statement.execute()
        if 1 != statement.getUpdateCount()
          raise MiniORM::MiniORMRecordNotFoundException, "#{self.class.name} id #{id} does not exist in database for update"
        end
      end
    end
    KApp.logger.info("DB #{self.class.name}: UPDATE row id #{@id}")
    after_update()
  end

  # -------------------------------------------------------------------------

  def self._sql_fragment(name)
    f = self.const_get(name)
    "#{f.first}#{self.db_schema_name}#{f.last}"
  end

  def self.db_schema_name
    KApp.db_schema_name
  end

  def _table
    self.class.const_get(:TABLE)
  end

  def _write_attribute(column, value, current_value)
    # So that attribute_changed? only returns true when the value is actually changed,
    # compare before setting. However, if the record hasn't been saved yet, need to
    # save new value anyway, so nil can be assigned to attributes in new records.
    unless (current_value == value) && (@id != nil)
      @_dirty_values ||= {}
      @_dirty_values[column] = value
    end
  end

end
