require File.join(File.dirname(__FILE__), '..', 'spec_helper')

module Cash
  describe 'Range' do

    describe '#initialize' do
      it 'does not support ranges by default' do
        Story.cache_config.indices.first.supports_ranges?.should be_false
      end
      
      it 'supports ranges for specified attributes' do
        Fable.cache_config.indices.first.attributes.should == ["num_pages"]
        Fable.cache_config.indices.first.supports_ranges?.should be_true
      end
    end
    
    describe '#create' do
      describe 'when the index supports ranges' do
        it 'writes records into the regurlar cache at primary key' do
          fable = Fable.create!(:author => 'Sam', :num_pages => '123')
          Fable.get("id/#{fable.id}").should == [fable]
        end
        
        it 'writes records into the range cache at the correct keys' do
          fable = Fable.create!(:author => 'Sam', :num_pages => '6')
          Fable.get("num_pages/6").should == [fable.id]
          
          fable = Fable.create!(:author => 'Sam', :num_pages => '106')
          Fable.get("num_pages/1**").should == [fable.id]
          Fable.get("num_pages/10*").should == [fable.id]
          Fable.get("num_pages/106").should == [fable.id]
        end
        
        it 'appends records to range cache when keys match' do
          fable1 = Fable.create!(:author => 'Sam', :num_pages => '6')
          fable2 = Fable.create!(:author => 'Kumar', :num_pages => '6')
          Fable.get("num_pages/6").should == [fable1.id, fable2.id]
        end
      end
      
      describe 'when the index does not support ranges' do
        it 'writes records into the regurlar cache at primary key' do
          tale = Tale.create!(:title => 'I am debonair', :height => 10)
          Tale.get("id/#{tale.id}").should == [tale]
        end
        
        it 'does not write into the range cache' do
          tale = Tale.create!(:title => 'I am debonair', :height => 10)
          Tale.get("height/1*").should == nil
          Tale.get("height/10").should == nil
        end
      end
    end
    
    describe '#find(:all, :conditions => {:date => (start..end)}, ...)' do
      describe 'when the index does not support ranges' do
        it 'does not create a bogus cache entry for id' do
          story1 = Story.create!(:title => "I am terse")
          story2 = Story.create!(:title => "I am verbose")
          story3 = Story.create!(:title => "I am grandiloquent")
          Story.find(:all, :conditions => { :id => (story2.id..story3.id) })
          Story.get("id/2..3").should be_nil
        end
      end
      
      describe 'when the index does support ranges' do
        
        it 'does not create a bogus cache entry for id' do
          story1 = Story.create!(:title => "I am terse")
          story2 = Story.create!(:title => "I am verbose")
          story3 = Story.create!(:title => "I am grandiloquent")
          Story.find(:all, :conditions => { :id => (story2.id..story3.id) })
          Story.get("id/2..3").should be_nil
        end
        
        describe 'when the range cache is prepopulated' do
          it 'uses the range cache' do
            fable1 = Fable.create!(:author => 'Sam', :num_pages => '6')
            fable2 = Fable.create!(:author => 'John', :num_pages => '7')
            fable3 = Fable.create!(:author => 'Bob', :num_pages => '8')
            Fable.find(:all, :conditions => { :num_pages => (6..8) })
          end
        end
        
        describe 'when the range cache is empty' do
          it 'populates the range cache' do
            fable1 = Fable.create!(:author => 'Sam', :num_pages => '6')
            fable2 = Fable.create!(:author => 'John', :num_pages => '7')
            fable3 = Fable.create!(:author => 'Bob', :num_pages => '8')
            $memcache.flush_all
            Fable.find(:all, :conditions => { :num_pages => (6..8) })            
          end
        end
        
        describe 'when the range cache is partially populated' do
          it 'fills the cache and then uses it' do
            fable2 = Fable.create!(:author => 'John', :num_pages => '7')
            $memcache.flush_all            
            fable1 = Fable.create!(:author => 'Sam', :num_pages => '6')
            fable3 = Fable.create!(:author => 'Bob', :num_pages => '8')
            Fable.find(:all, :conditions => { :num_pages => (6..8) })
          end
        end
      end
    end
  end
end