class RangeData
  attr_accessor :data, :parent
  def initialize(data, parent = nil)
    @data, @parent = data, parent
  end
end