#!/usr/bin/perl -w

use utf8;
use strict;
use WWW::Mechanize;
use HTML::TreeBuilder;
use Encode;
use Date::Calc qw(:all);
use DateTime::Duration;
use Net::Google::Calendar;

binmode STDOUT, ":utf8";

# 図書館カードの設定
my @card_list = (
  {id => '図書館のカード番号', password =>'図書館のパスワード', name => '任意の名前'},
 #{id => '1234567891', password =>'パスワード', name => '任意の名前'},
 #{id => '1234567892', password =>'パスワード', name => '任意の名前'},
  );
my $library_location = "横浜市立図書館";

# Googleカレンダーの設定
my $username = 'GmailのID@gmail.com';
my $password = 'Gmailのパスワード';
my $mycalname = 'カレンダーの名前';

# 登録のトリガーとなる日（返却までの日数）
my $remainder_days = 14;

my $url = 'https://www.lib.city.yokohama.jp/cgi-bin/Swwwskce.sh?0';
foreach my $book (&get_book_list($url, @card_list)){
  if( $book->{remainder_days} == $remainder_days ){
    add_due_date_to_gcal($book);
  }
}

sub add_due_date_to_gcal {
  my($book) = @_;

  my $cal = Net::Google::Calendar->new();
  $cal->login($username, $password);

  my $c;
  for ($cal->get_calendars) {
    $c = $_ if ($_->title eq $mycalname);
  }
  $cal->set_calendar($c);

  my $entry = Net::Google::Calendar::Entry->new();
  $entry->title( "図書返却: $book->{title}" );
  $entry->content( "題名:$book->{title}<br>ISBN:$book->{isbn}" );
  $entry->when( $book->{due_date}, $book->{due_date}, 'allday' );
  $entry->location( $library_location );
  $entry->transparency( 'transparent' );
  $entry->status( 'confirmed' );

  $cal->add_entry($entry);
}

sub get_book_list {
  my($url, @card_list) = @_;
  my @book_list;
  foreach my $card (@card_list){
    my($user, $pass, $name)=($card->{id}, $card->{password}, $card->{name});
    my $mech = WWW::Mechanize->new;
    $mech->agent_alias('Windows IE 6');
    $mech->get($url);
    $mech->submit_form(
      fields	=> {
        ryno => $user,
        pswd => $pass,
      }
      );
    my $html = decode('euc-jp', $mech->content());
    my $tree = HTML::TreeBuilder->new;
    $tree->parse($html);
    $tree->eof();
    foreach my $book ($tree->look_down(_tag=>'a', href=>qr/Swwwskke/)) {
      my $current = $book->as_text;
      $current =~ m/^(\d+) +(..) (\d\d\.\d\d) (  |.) (\d\d\.\d\d) (  |.) ([^ ]+) +(.+) +$/;
      my($item_id, $borrowed_mmdd, $notice, $due_mmdd, $subscribed_mark, $title) = ($1, $3, $4, $5, $6, $8);
      $title =~ s/(^\s+|\s+$)//;

      my $detail_url = URI->new_abs($book->attr('href'), $url)->as_string;
      $mech->get($detail_url);
      my $html = decode('euc-jp', $mech->content());
      my $isbn;
      my $extensionable=1;	#1:延長可, 0:不可
      if($subscribed_mark =~ m/＊/){
        $extensionable=0;
      }
      if($html =~ m/^.*ＩＳＢＮ　：([^ ]*).*$/s){
        $isbn=$1;
      } else {
        $extensionable=0;
        # $codeで検索してisbnを取り出す
        $mech->get('http://www.lib.city.yokohama.jp/cgi-bin/Swwwsmin.sh?0');
        $mech->submit_form(
          fields=>{
            tgid=>'SRNO', tkey=>$item_id,
          }
          );
        $html=decode('euc-jp', $mech->content());
        my $tree = HTML::TreeBuilder->new;
        $tree->parse($html);
        $tree->eof();
        foreach my $a ($tree->look_down(_tag=>'a', href=>qr/Swwwsvis/)){
          my $kensaku_url = URI->new_abs($a->attr('href'), $url)->as_string();
          $mech->get($kensaku_url);
          $html = decode('euc-jp', $mech->content());
          $html =~ m/^.*ＩＳＢＮ　：([^ ]*).*$/s;
          $isbn = $1;
          last;
        }
      }

      my($cyear, $cmonth, $cday) = Today();
      my $due_year = This_Year();
      my($due_month, $due_day) = split('\.', $due_mmdd);
      my $borrowed_year = This_Year();
      my($borrowed_month, $borrowed_day) = split('\.', $borrowed_mmdd);

      my $due_date = DateTime->new(#time_zone => "Asia/Tokyo",
                                   year      => $due_year,
                                   month     => $due_month,
                                   day       => $due_day);
      my $borrowed_date = DateTime->new(#time_zone=>"Asia/Tokyo",
                                        year  => $borrowed_year,
                                        month => $borrowed_month,
                                        day   => $borrowed_day );

      # 貸出も返却も今年と仮定して算出した貸出日が返却日より未来のときは、
      # 年越しの貸し出しになっているので、年を変更して計算しなおす。
      # あやしい。
      if( $borrowed_date > $due_date ){
        
        #今月が返却月でなければ、返却は来年。そうでなければ貸出が去年
        if( $due_date->month() != This_Month() ){
          # 返却が来年
          $due_year = This_Year()+1;
          $due_date = DateTime->new(#time_zone => "Asia/Tokyo",
                                    year      => $due_year,
                                    month     => $due_month,
                                    day       => $due_day);
        }else{
          # 貸出が去年
          $borrowed_year = This_Year()-1;
          $borrowed_date = DateTime->new(#time_zone => "Asia/Tokyo",
                                         year      => $borrowed_year,
                                         month     => $borrowed_month,
                                         day       => $borrowed_day );
        }
      }
      
      my $remainder_days = Delta_Days( $cyear, $cmonth, $cday, $due_year, $due_month, $due_day );
      my $past_days = Delta_Days( $borrowed_year, $borrowed_month, $borrowed_day, $cyear, $cmonth, $cday );

      push @book_list, {
        title          => $title,
        item_id        => $item_id,
        remainder_days => $remainder_days,
        borrowed_date  => $borrowed_date,
        due_date       => $due_date,
        isbn           => $isbn,
        extensionable  => $extensionable,
        card_owner     => $name,
        link           => $detail_url,
      }
    }
  }
  @book_list=sort {$a->{remainder_days} <=> $b->{remainder_days}} @book_list;

  return @book_list;
}

