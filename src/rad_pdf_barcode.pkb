CREATE OR REPLACE PACKAGE BODY rad_pdf_barcode IS
/*
  rad_pdf_barcode body — Phase 10: barcode / QR code rendering.

  Structure:
    1. "PORTED" section — QR encoding logic (bit stream, Reed-Solomon ECC,
       matrix patterns, masking) ported from AS_BARCODE by Anton Scheffer,
       kept in its original lowercase style to stay diffable against
       upstream (https://github.com/antonscheffer/as_barcode).
       Adaptations: JSON p_parm options replaced by explicit parameters;
       NVARCHAR2 support dropped (API is VARCHAR2); data encoded verbatim
       (no backslash doubling in ECI mode).
    2. House-style public API — vector renderer on rad_pdf_canvas.path.

  ===========================================================================
  Ported code: Copyright (C) 2016-2024 by Anton Scheffer (MIT license)

  Permission is hereby granted, free of charge, to any person obtaining a
  copy of this software and associated documentation files (the "Software"),
  to deal in the Software without restriction, including without limitation
  the rights to use, copy, modify, merge, publish, distribute, sublicense,
  and/or sell copies of the Software, and to permit persons to whom the
  Software is furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included
  in all copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
  THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
  DEALINGS IN THE SOFTWARE.
  ===========================================================================
*/

-- ---------------------------------------------------------------------------
-- Private types (matrix of modules: 0 = light, 1 = dark)
-- matrix(outer)(inner) = (column, row-from-top) — see renderer mapping.
-- ---------------------------------------------------------------------------
  type tp_bits is table of pls_integer index by pls_integer;
  type tp_matrix is table of tp_bits index by pls_integer;

-- ===========================================================================
-- PORTED FROM as_barcode (MIT) — begin
-- ===========================================================================
  function bitxor( x number, y number )
  return number
  is
  begin
    return x + y - 2 * bitand( x, y );
  end;
  --
  procedure append_bits( p_bits in out tp_bits, p_val number, p_cnt number )
  is
  begin
    for j in reverse 0 .. p_cnt - 1
    loop
      p_bits( p_bits.count ) := sign( bitand( p_val, power( 2, j ) ) );
    end loop;
  end;
  function bitstoword( p_bits tp_bits, p_sz pls_integer )
  return tp_bits
  is
    l_val pls_integer;
    l_rv tp_bits;
    l_first pls_integer := p_bits.first;
  begin
    for i in l_first ..  p_bits.count / p_sz - l_first - 1
    loop
      l_val := 0;
      for j in 0 .. p_sz - 1
      loop
        l_val := l_val * 2 + p_bits( l_first + ( i - l_first ) * p_sz + j );
      end loop;
      l_rv( i - l_first ) := l_val;
    end loop;
    return l_rv;
  end;
  function reed_solomon
    ( p_data tp_bits
    , p_primitive pls_integer := 285
    , p_size pls_integer := 256
    , p_degree pls_integer := 16
    , p_b pls_integer := 1
    )
  return tp_bits
  is
    type tp_ecc is table of pls_integer index by pls_integer;
    t_exp tp_ecc;
    t_log tp_ecc;
    t_g tp_ecc;
    t_ecc tp_ecc;
    t_x pls_integer;
    t_rv tp_bits;
--
  begin
    t_x := 1;
    for i in 0 .. p_size - 1
    loop
      t_exp( i ) := t_x;
      t_x := t_x * 2;
      if t_x >= p_size
      then
        t_x := bitand( p_size - 1, bitxor( p_primitive, t_x ) );
      end if;
    end loop;
    for i in 0 .. p_size - 2
    loop
      t_log( t_exp( i ) ) := i;
    end loop;
--
    t_g(0) := 1;
    for i in 1 .. p_degree
    loop
      t_x := i - 1 + p_b;
      t_g(i) := t_exp( mod( t_log( t_g( i-1 ) ) + t_x, p_size - 1 ) );
      for j in reverse 1 .. i - 1
      loop
        t_g(j) := bitxor( t_exp( mod( t_log(t_g(j-1)) + t_x, p_size - 1 ) )
                        , t_g(j)
                        );
      end loop;
-- t_log( 1 ) is altijd 0
 --     t_g(0) := bitxor( 0, t_exp( t_log( t_g( 0 ) ) + t_log( 1 ) ) );
    end loop;
--
    t_x := p_data.first;
    for i in t_x .. p_data.last
    loop
      t_ecc( i - t_x ) := p_data( i );
    end loop;
    for i in t_ecc.count .. t_ecc.count + p_degree - 1
    loop
      t_ecc( i ) := 0;
    end loop;
    --
    while t_ecc.count >= t_g.count
    loop
      t_x := t_ecc( t_ecc.first );
      if t_x > 0 then
        for i in 0 .. t_g.count - 1
        loop
            t_ecc( t_ecc.first + i ) := bitxor( t_ecc( t_ecc.first + i )
                                              , t_exp( mod( t_log( t_g( i ) ) + t_log( t_x ), p_size - 1 ) )
                                              );
        end loop;
      end if;
      t_ecc.delete( t_ecc.first );
    end loop;
    --
    t_x := t_ecc.first;
    for i in t_ecc.first .. t_ecc.last
    loop
      t_rv( i - t_x ) := t_ecc( i );
    end loop;
    return t_rv;
  end;
  procedure add_quiet( p_matrix in out nocopy tp_matrix, p_quiet pls_integer )
  is
    l_height pls_integer := p_matrix.count;
    l_width  pls_integer := p_matrix( p_matrix.first ).count;
    l_quiet pls_integer;
  begin
    l_quiet := nvl( p_quiet, 0 );
    if l_quiet = 0
    then
      return;
    end if;
    for i in reverse 0 .. l_height - 1 loop
      for j in reverse 0 .. l_width - 1 loop
        p_matrix( i + l_quiet )( j + l_quiet ) := p_matrix(i)(j);
      end loop;
      for j in 0 .. l_quiet - 1 loop
        p_matrix( i + l_quiet )(j) := 0;
        p_matrix( i + l_quiet )( j + l_width + l_quiet ) := 0;
      end loop;
    end loop;
    for j in 0 .. l_width + 2 * l_quiet - 1 loop
      p_matrix(0)(j) := 0;
    end loop;
    for i in 0 .. l_quiet - 1 loop
      p_matrix(i) := p_matrix(0);
      p_matrix( i + l_quiet + l_height ) := p_matrix(0);
    end loop;
  end add_quiet;
  procedure gen_qrcode_matrix( p_val varchar2
                             , p_ec_level varchar2
                             , p_matrix out tp_matrix
                             )
  is
    l_version pls_integer;
    l_eclevel pls_integer;
    l_stream tp_bits;
    l_tmp    raw(32767);
    l_sz  pls_integer;
    l_len pls_integer;
    type tp_config is table of pls_integer;
    type tp_ecc_config is table of tp_config;
    type tp_qr_config is table of tp_ecc_config;
    l_qr_config tp_qr_config;
    --
    function get_formatinfo( p_eclevel in pls_integer, p_mask pls_integer )
    return pls_integer
    is
      type tp_format is table of tp_config;
      l_format tp_format;
    begin
      l_format := tp_format( tp_config( 30660, 29427, 32170, 30877, 26159, 25368, 27713, 26998 )
                           , tp_config( 21522, 20773, 24188, 23371, 17913, 16590, 20375, 19104 )
                           , tp_config( 13663, 12392, 16177, 14854, 9396, 8579, 11994, 11245 )
                           , tp_config( 5769, 5054, 7399, 6608, 1890, 597, 3340, 2107 )
                           );
      return l_format( p_eclevel )( p_mask + 1 );
    end;
    --
    procedure add_patterns( p_version pls_integer
                          , p_matrix in out nocopy tp_matrix
                          )
    is
      l_width pls_integer := 4 * p_version + 17;
      type tp_inf is table of pls_integer;
      type tp_pos is table of pls_integer;
      type tp_align is table of tp_pos;
      l_align tp_align;
      l_info tp_inf;
      l_version_info pls_integer;
      l_cnt pls_integer;
      l_bit pls_integer;
      --
      procedure add_finder( p_x pls_integer, p_y pls_integer, p_w pls_integer )
      is
        l_sx pls_integer := case p_w when 2 then l_width -  8 else 7 end;
        l_sy pls_integer := case p_w when 3 then l_width -  8 else 7 end;
        l_dx pls_integer := case p_w when 2 then 1 else -1 end;
        l_dy pls_integer := case p_w when 3 then 1 else -1 end;
      begin
        for i in -3 .. 3 loop
          for j in -3 .. 3 loop
            p_matrix( p_x + i )( p_y + j ) := 1;
          end loop;
        end loop;
        for i in -2 .. 2 loop
          p_matrix( p_x + i )( p_y - 2 ) := 0;
          p_matrix( p_x + i )( p_y + 2 ) := 0;
          p_matrix( p_x - 2 )( p_y + i ) := 0;
          p_matrix( p_x + 2 )( p_y - i ) := 0;
        end loop;
        for i in 0 .. 7 loop
          p_matrix( p_x + ( i - 4 ) * l_dx )( p_y - 4 * l_dy ) := 0;
          if p_w != 3
          then  -- reserved for format information
            p_matrix( p_x + ( i - 4 ) * l_dx )( p_y + 5 ) := 1;
          end if;
          p_matrix( p_x - 4 * l_dx )( p_y + ( i - 4 ) * l_dy ) := 0;
          if p_w != 2
          then  -- reserved for format information
            p_matrix( p_x + 5 )( p_y + ( i - 4 ) * l_dy ) := 1;
          end if;
        end loop;
      end;
      --
      procedure add_aligment( p_x pls_integer, p_y pls_integer )
      is
      begin
        for i in -2 .. 2 loop
          for j in -2 .. 2 loop
            p_matrix( p_x + i )( p_y + j ) := 1;
          end loop;
        end loop;
        for i in -1 .. 1 loop
          p_matrix( p_x + i )( p_y - 1 ) := 0;
          p_matrix( p_x + i )( p_y + 1 ) := 0;
        end loop;
        p_matrix( p_x + 1 )( p_y ) := 0;
        p_matrix( p_x - 1 )( p_y ) := 0;
      end;
    begin
      for r in 0 .. l_width - 1
      loop
        for c in 0 .. l_width - 1
        loop
          p_matrix( r )( c ) := 3; -- init everything to dark
        end loop;
      end loop;
      --
      add_finder( 3, 3, 1 );
      add_finder( l_width - 4, 3, 2 );
      add_finder( 3, l_width - 4, 3 );
      p_matrix( 8 )( 8 ) := 1; -- reserved for format information
      --
      for i in 8 .. l_width - 9 loop
        p_matrix( i )( 6 ) := 1 - mod( i, 2 ); -- timing
        p_matrix( 6 )( i ) := 1 - mod( i, 2 ); -- timing
      end loop;
      --
      if p_version > 1
      then
        add_aligment( l_width - 7, l_width - 7 );
        if p_version > 6
        then
          l_align := tp_align( tp_pos( 6, 22, 38 ) -- 7
                             , tp_pos( 6, 24, 42 ) -- 8
                             , tp_pos( 6, 26, 46 ) -- 9
                             , tp_pos( 6, 28, 50 ) -- 10
                             , tp_pos( 6, 30, 54 ) -- 11
                             , tp_pos( 6, 32, 58 ) -- 12
                             , tp_pos( 6, 34, 62 ) -- 13
                             , tp_pos( 6, 26, 46, 66 ) -- 14
                             , tp_pos( 6, 26, 48, 70 ) -- 15
                             , tp_pos( 6, 26, 50, 74 ) -- 16
                             , tp_pos( 6, 30, 54, 78 ) -- 17
                             , tp_pos( 6, 30, 56, 82 ) -- 18
                             , tp_pos( 6, 30, 58, 86 ) -- 19
                             , tp_pos( 6, 34, 62, 90 ) -- 20
                             , tp_pos( 6, 28, 50, 72,  94 ) -- 21
                             , tp_pos( 6, 26, 50, 74,  98 ) -- 22
                             , tp_pos( 6, 30, 54, 78, 102 ) -- 23
                             , tp_pos( 6, 28, 54, 80, 106 ) -- 24
                             , tp_pos( 6, 32, 58, 84, 110 ) -- 25
                             , tp_pos( 6, 30, 58, 86, 114 ) -- 26
                             , tp_pos( 6, 34, 62, 90, 118 ) -- 27
                             , tp_pos( 6, 26, 50, 74,  98, 122 ) -- 28
                             , tp_pos( 6, 30, 54, 78, 102, 126 ) -- 29
                             , tp_pos( 6, 26, 52, 78, 104, 130 ) -- 30
                             , tp_pos( 6, 30, 56, 82, 108, 134 ) -- 31
                             , tp_pos( 6, 34, 60, 86, 112, 138 ) -- 32
                             , tp_pos( 6, 30, 58, 86, 114, 142 ) -- 33
                             , tp_pos( 6, 34, 62, 90, 118, 146 ) -- 34
                             , tp_pos( 6, 30, 54, 78, 102, 126, 150 ) -- 35
                             , tp_pos( 6, 24, 50, 76, 102, 128, 154 ) -- 36
                             , tp_pos( 6, 28, 54, 80, 106, 132, 158 ) -- 37
                             , tp_pos( 6, 32, 58, 84, 110, 136, 162 ) -- 38
                             , tp_pos( 6, 26, 54, 82, 110, 138, 166 ) -- 39
                             , tp_pos( 6, 30, 58, 86, 114, 142, 170 ) -- 40
                             );
          l_cnt := l_align( l_version - 6 ).count;
          for i in 1 .. l_cnt loop
            for j in 1 .. l_cnt loop
              if i between 2 and l_cnt - 1 or j between 2 and l_cnt - 1
              then
                add_aligment( l_align( l_version - 6 )( i )
                            , l_align( l_version - 6 )( j )
                            );
              end if;
            end loop;
          end loop;
          --
          l_info := tp_inf
            ( 31892, 34236, 39577, 42195, 48118, 51042, 55367, 58893, 63784
            , 68472, 70749, 76311, 79154, 84390, 87683, 92361, 96236, 102084
            , 102881, 110507, 110734, 117786, 119615, 126325, 127568, 133589
            , 136944, 141498, 145311, 150283, 152622, 158308, 161089, 167017
            );
          l_version_info := l_info( l_version - 6 );
          for i in 0 .. 5
          loop
            for j in 0 .. 2
            loop
              l_bit := sign( bitand( l_version_info, power( 2, i * 3 + j ) ) );
              p_matrix( l_width - 11 + j )( i ) := l_bit; -- lower left
              p_matrix( i )( l_width - 11 + j ) := l_bit; -- upper right
            end loop;
          end loop;
        end if;
      end if;
    end add_patterns;
    --
    procedure add_stream( p_width pls_integer
                        , p_stream tp_bits
                        , p_matrix in out nocopy tp_matrix
                        )
    is
      l_x pls_integer;
      l_y pls_integer;
      l_direction pls_integer := -1;
      procedure next_pos
      is
      begin
        if l_x is null
        then
          l_x := p_width - 1;
          l_y := p_width - 1;
        else
          if (  l_x > 5 and mod( l_x, 2 ) = 0
             or l_x < 6 and mod( l_x, 2 ) = 1
             )
          then
            l_x := l_x - 1;
          else
            l_x := l_x + 1;
            l_y := l_y + l_direction;
          end if;
          if l_y < 0
          then
            l_x := l_x - case when l_x = 8 then 3 else 2 end; -- skip vertical timing column
            l_y := 0;
            l_direction := 1;
          elsif l_y >= p_width
          then
            l_x := l_x - 2;
            l_y := p_width - 1;
            l_direction := - 1;
          end if;
          if l_y = 6 or l_x = 6 or p_matrix( l_x )( l_y ) != 3
          then
            next_pos;
          end if;
        end if;
      end;
    begin
      for i in 0 .. p_stream.count - 1
      loop
        next_pos;
        p_matrix( l_x )( l_y ) := 128 + p_stream( i );
      end loop;
      -- remainder bits
      for i in 0 .. 1 loop
        for j in 9 .. p_width - 8 loop
          if p_matrix( i )( j ) between 2 and 127
          then
            p_matrix( i )( j ) := 128;
          end if;
        end loop;
      end loop;
    end add_stream;
    --
    function get_qr_config
    return tp_qr_config
    is
    begin
      return tp_qr_config( tp_ecc_config( tp_config( 19,7,41,25,17,16,1,1,19 ) -- 1
                                        , tp_config( 16,10,34,20,14,13,1,1,16 )
                                        , tp_config( 13,13,27,16,11,10,1,1,13 )
                                        , tp_config( 9,17,17,10,7,6,1,1,9 )
                                        )
                         , tp_ecc_config( tp_config( 34,10,77,47,32,31,1,1,34 ) -- 2
                                        , tp_config( 28,16,63,38,26,25,1,1,28 )
                                        , tp_config( 22,22,48,29,20,19,1,1,22 )
                                        , tp_config( 16,28,34,20,14,13,1,1,16 )
                                        )
                         , tp_ecc_config( tp_config( 55,15,127,77,53,52,1,1,55 ) -- 3
                                        , tp_config( 44,26,101,61,42,41,1,1,44 )
                                        , tp_config( 34,36,77,47,32,31,1,2,17 )
                                        , tp_config( 26,44,58,35,24,23,1,2,13 )
                                        )
                         , tp_ecc_config( tp_config( 80,20,187,114,78,77,1,1,80 ) -- 4
                                        , tp_config( 64,36,149,90,62,61,1,2,32 )
                                        , tp_config( 48,52,111,67,46,45,1,2,24 )
                                        , tp_config( 36,64,82,50,34,33,1,4,9 )
                                        )
                         , tp_ecc_config( tp_config( 108,26,255,154,106,105,1,1,108 ) -- 5
                                        , tp_config( 86,48,202,122,84,83,1,2,43 )
                                        , tp_config( 62,72,144,87,60,59,2,2,15,2,16 )
                                        , tp_config( 46,88,106,64,44,43,2,2,11,2,12 )
                                        )
                         , tp_ecc_config( tp_config( 136,36,322,195,134,133,1,2,68 ) -- 6
                                        , tp_config( 108,64,255,154,106,105,1,4,27 )
                                        , tp_config( 76,96,178,108,74,73,1,4,19 )
                                        , tp_config( 60,112,139,84,58,57,1,4,15 )
                                        )
                         , tp_ecc_config( tp_config( 156,40,370,224,154,153,1,2,78 ) -- 7
                                        , tp_config( 124,72,293,178,122,121,1,4,31 )
                                        , tp_config( 88,108,207,125,86,85,2,2,14,4,15 )
                                        , tp_config( 66,130,154,93,64,63,2,4,13,1,14 )
                                        )
                         , tp_ecc_config( tp_config( 194,48,461,279,192,191,1,2,97 ) -- 8
                                        , tp_config( 154,88,365,221,152,151,2,2,38,2,39 )
                                        , tp_config( 110,132,259,157,108,107,2,4,18,2,19 )
                                        , tp_config( 86,156,202,122,84,83,2,4,14,2,15 )
                                        )
                         , tp_ecc_config( tp_config( 232,60,552,335,230,229,1,2,116 ) -- 9
                                        , tp_config( 182,110,432,262,180,179,2,3,36,2,37 )
                                        , tp_config( 132,160,312,189,130,129,2,4,16,4,17 )
                                        , tp_config( 100,192,235,143,98,97,2,4,12,4,13 )
                                        )
                         , tp_ecc_config( tp_config( 274,72,652,395,271,270,2,2,68,2,69 ) -- 10
                                        , tp_config( 216,130,513,311,213,212,2,4,43,1,44 )
                                        , tp_config( 154,192,364,221,151,150,2,6,19,2,20 )
                                        , tp_config( 122,224,288,174,119,118,2,6,15,2,16 )
                                        )
                         , tp_ecc_config( tp_config( 324,80,772,468,321,320,1,4,81 ) -- 11
                                        , tp_config( 254,150,604,366,251,250,2,1,50,4,51 )
                                        , tp_config( 180,224,427,259,177,176,2,4,22,4,23 )
                                        , tp_config( 140,264,331,200,137,136,2,3,12,8,13 )
                                        )
                         , tp_ecc_config( tp_config( 370,96,883,535,367,366,2,2,92,2,93 ) -- 12
                                        , tp_config( 290,176,691,419,287,286,2,6,36,2,37 )
                                        , tp_config( 206,260,489,296,203,202,2,4,20,6,21 )
                                        , tp_config( 158,308,374,227,155,154,2,7,14,4,15 )
                                        )
                         , tp_ecc_config( tp_config( 428,104,1022,619,425,424,1,4,107 ) -- 13
                                        , tp_config( 334,198,796,483,331,330,2,8,37,1,38 )
                                        , tp_config( 244,288,580,352,241,240,2,8,20,4,21 )
                                        , tp_config( 180,352,427,259,177,176,2,12,11,4,12 )
                                        )
                         , tp_ecc_config( tp_config( 461,120,1101,667,458,457,2,3,115,1,116 ) -- 14
                                        , tp_config( 365,216,871,528,362,361,2,4,40,5,41 )
                                        , tp_config( 261,320,621,376,258,257,2,11,16,5,17 )
                                        , tp_config( 197,384,468,283,194,193,2,11,12,5,13 )
                                        )
                         , tp_ecc_config( tp_config( 523,132,1250,758,520,519,2,5,87,1,88 ) -- 15
                                        , tp_config( 415,240,991,600,412,411,2,5,41,5,42 )
                                        , tp_config( 295,360,703,426,292,291,2,5,24,7,25 )
                                        , tp_config( 223,432,530,321,220,219,2,11,12,7,13 )
                                        )
                         , tp_ecc_config( tp_config( 589,144,1408,854,586,585,2,5,98,1,99 ) -- 16
                                        , tp_config( 453,280,1082,656,450,449,2,7,45,3,46 )
                                        , tp_config( 325,408,775,470,322,321,2,15,19,2,20 )
                                        , tp_config( 253,480,602,365,250,249,2,3,15,13,16 )
                                        )
                         , tp_ecc_config( tp_config( 647,168,1548,938,644,643,2,1,107,5,108 ) -- 17
                                        , tp_config( 507,308,1212,734,504,503,2,10,46,1,47 )
                                        , tp_config( 367,448,876,531,364,363,2,1,22,15,23 )
                                        , tp_config( 283,532,674,408,280,279,2,2,14,17,15 )
                                        )
                         , tp_ecc_config( tp_config( 721,180,1725,1046,718,717,2,5,120,1,121 ) -- 18
                                        , tp_config( 563,338,1346,816,560,559,2,9,43,4,44 )
                                        , tp_config( 397,504,948,574,394,393,2,17,22,1,23 )
                                        , tp_config( 313,588,746,452,310,309,2,2,14,19,15 )
                                        )
                         , tp_ecc_config( tp_config( 795,196,1903,1153,792,791,2,3,113,4,114 ) -- 19
                                        , tp_config( 627,364,1500,909,624,623,2,3,44,11,45 )
                                        , tp_config( 445,546,1063,644,442,441,2,17,21,4,22 )
                                        , tp_config( 341,650,813,493,338,337,2,9,13,16,14 )
                                        )
                         , tp_ecc_config( tp_config( 861,224,2061,1249,858,857,2,3,107,5,108 ) -- 20
                                        , tp_config( 669,416,1600,970,666,665,2,3,41,13,42 )
                                        , tp_config( 485,600,1159,702,482,481,2,15,24,5,25 )
                                        , tp_config( 385,700,919,557,382,381,2,15,15,10,16 )
                                        )
                         , tp_ecc_config( tp_config( 932,224,2232,1352,929,928,2,4,116,4,117 ) -- 21
                                        , tp_config( 714,442,1708,1035,711,710,1,17,42 )
                                        , tp_config( 512,644,1224,742,509,508,2,17,22,6,23 )
                                        , tp_config( 406,750,969,587,403,402,2,19,16,6,17 )
                                        )
                         , tp_ecc_config( tp_config( 1006,252,2409,1460,1003,1002,2,2,111,7,112 ) -- 22
                                        , tp_config( 782,476,1872,1134,779,778,1,17,46 )
                                        , tp_config( 568,690,1358,823,565,564,2,7,24,16,25 )
                                        , tp_config( 442,816,1056,640,439,438,1,34,13 )
                                        )
                         , tp_ecc_config( tp_config( 1094,270,2620,1588,1091,1090,2,4,121,5,122 ) -- 23
                                        , tp_config( 860,504,2059,1248,857,856,2,4,47,14,48 )
                                        , tp_config( 614,750,1468,890,611,610,2,11,24,14,25 )
                                        , tp_config( 464,900,1108,672,461,460,2,16,15,14,16 )
                                        )
                         , tp_ecc_config( tp_config( 1174,300,2812,1704,1171,1170,2,6,117,4,118 ) -- 24
                                        , tp_config( 914,560,2188,1326,911,910,2,6,45,14,46 )
                                        , tp_config( 664,810,1588,963,661,660,2,11,24,16,25 )
                                        , tp_config( 514,960,1228,744,511,510,2,30,16,2,17 )
                                        )
                         , tp_ecc_config( tp_config( 1276,312,3057,1853,1273,1272,2,8,106,4,107 ) -- 25
                                        , tp_config( 1000,588,2395,1451,997,996,2,8,47,13,48 )
                                        , tp_config( 718,870,1718,1041,715,714,2,7,24,22,25 )
                                        , tp_config( 538,1050,1286,779,535,534,2,22,15,13,16 )
                                        )
                         , tp_ecc_config( tp_config( 1370,336,3283,1990,1367,1366,2,10,114,2,115 ) -- 26
                                        , tp_config( 1062,644,2544,1542,1059,1058,2,19,46,4,47 )
                                        , tp_config( 754,952,1804,1094,751,750,2,28,22,6,23 )
                                        , tp_config( 596,1110,1425,864,593,592,2,33,16,4,17 )
                                        )
                         , tp_ecc_config( tp_config( 1468,360,3517,2132,1465,1464,2,8,122,4,123 ) -- 27
                                        , tp_config( 1128,700,2701,1637,1125,1124,2,22,45,3,46 )
                                        , tp_config( 808,1020,1933,1172,805,804,2,8,23,26,24 )
                                        , tp_config( 628,1200,1501,910,625,624,2,12,15,28,16 )
                                        )
                         , tp_ecc_config( tp_config( 1531,390,3669,2223,1528,1527,2,3,117,10,118 ) -- 28
                                        , tp_config( 1193,728,2857,1732,1190,1189,2,3,45,23,46 )
                                        , tp_config( 871,1050,2085,1263,868,867,2,4,24,31,25 )
                                        , tp_config( 661,1260,1581,958,658,657,2,11,15,31,16 )
                                        )
                         , tp_ecc_config( tp_config( 1631,420,3909,2369,1628,1627,2,7,116,7,117 ) -- 29
                                        , tp_config( 1267,784,3035,1839,1264,1263,2,21,45,7,46 )
                                        , tp_config( 911,1140,2181,1322,908,907,2,1,23,37,24 )
                                        , tp_config( 701,1350,1677,1016,698,697,2,19,15,26,16 )
                                        )
                         , tp_ecc_config( tp_config( 1735,450,4158,2520,1732,1731,2,5,115,10,116 ) -- 30
                                        , tp_config( 1373,812,3289,1994,1370,1369,2,19,47,10,48 )
                                        , tp_config( 985,1200,2358,1429,982,981,2,15,24,25,25 )
                                        , tp_config( 745,1440,1782,1080,742,741,2,23,15,25,16 )
                                        )
                         , tp_ecc_config( tp_config( 1843,480,4417,2677,1840,1839,2,13,115,3,116 ) -- 31
                                        , tp_config( 1455,868,3486,2113,1452,1451,2,2,46,29,47 )
                                        , tp_config( 1033,1290,2473,1499,1030,1029,2,42,24,1,25 )
                                        , tp_config( 793,1530,1897,1150,790,789,2,23,15,28,16 )
                                        )
                         , tp_ecc_config( tp_config( 1955,510,4686,2840,1952,1951,1,17,115 ) -- 32
                                        , tp_config( 1541,924,3693,2238,1538,1537,2,10,46,23,47 )
                                        , tp_config( 1115,1350,2670,1618,1112,1111,2,10,24,35,25 )
                                        , tp_config( 845,1620,2022,1226,842,841,2,19,15,35,16 )
                                        )
                         , tp_ecc_config( tp_config( 2071,540,4965,3009,2068,2067,2,17,115,1,116 ) -- 33
                                        , tp_config( 1631,980,3909,2369,1628,1627,2,14,46,21,47 )
                                        , tp_config( 1171,1440,2805,1700,1168,1167,2,29,24,19,25 )
                                        , tp_config( 901,1710,2157,1307,898,897,2,11,15,46,16 )
                                        )
                         , tp_ecc_config( tp_config( 2191,570,5253,3183,2188,2187,2,13,115,6,116 ) -- 34
                                        , tp_config( 1725,1036,4134,2506,1722,1721,2,14,46,23,47 )
                                        , tp_config( 1231,1530,2949,1787,1228,1227,2,44,24,7,25 )
                                        , tp_config( 961,1800,2301,1394,958,957,2,59,16,1,17 )
                                        )
                         , tp_ecc_config( tp_config( 2306,570,5529,3351,2303,2302,2,12,121,7,122 ) -- 35
                                        , tp_config( 1812,1064,4343,2632,1809,1808,2,12,47,26,48 )
                                        , tp_config( 1286,1590,3081,1867,1283,1282,2,39,24,14,25 )
                                        , tp_config( 986,1890,2361,1431,983,982,2,22,15,41,16 )
                                        )
                         , tp_ecc_config( tp_config( 2434,600,5836,3537,2431,2430,2,6,121,14,122 ) -- 36
                                        , tp_config( 1914,1120,4588,2780,1911,1910,2,6,47,34,48 )
                                        , tp_config( 1354,1680,3244,1966,1351,1350,2,46,24,10,25 )
                                        , tp_config( 1054,1980,2524,1530,1051,1050,2,2,15,64,16 )
                                        )
                         , tp_ecc_config( tp_config( 2566,630,6153,3729,2563,2562,2,17,122,4,123 ) -- 37
                                        , tp_config( 1992,1204,4775,2894,1989,1988,2,29,46,14,47 )
                                        , tp_config( 1426,1770,3417,2071,1423,1422,2,49,24,10,25 )
                                        , tp_config( 1096,2100,2625,1591,1093,1092,2,24,15,46,16 )
                                        )
                         , tp_ecc_config( tp_config( 2702,660,6479,3927,2699,2698,2,4,122,18,123 ) -- 38
                                        , tp_config( 2102,1260,5039,3054,2099,2098,2,13,46,32,47 )
                                        , tp_config( 1502,1860,3599,2181,1499,1498,2,48,24,14,25 )
                                        , tp_config( 1142,2220,2735,1658,1139,1138,2,42,15,32,16 )
                                        )
                         , tp_ecc_config( tp_config( 2812,720,6743,4087,2809,2808,2,20,117,4,118 ) -- 39
                                        , tp_config( 2216,1316,5313,3220,2213,2212,2,40,47,7,48 )
                                        , tp_config( 1582,1950,3791,2298,1579,1578,2,43,24,22,25 )
                                        , tp_config( 1222,2310,2927,1774,1219,1218,2,10,15,67,16 )
                                        )
                         , tp_ecc_config( tp_config( 2956,750,7089,4296,2953,2952,2,19,118,6,119 ) -- 40
                                        , tp_config( 2334,1372,5596,3391,2331,2330,2,18,47,31,48 )
                                        , tp_config( 1666,2040,3993,2420,1663,1662,2,34,24,34,25 )
                                        , tp_config( 1276,2430,3057,1852,1273,1272,2,20,15,61,16 )
                                        )
                         );
    end get_qr_config;
    --
    function get_version( p_len pls_integer
                        , p_eclevel pls_integer
                        , p_mode pls_integer
                        )
    return pls_integer
    is
      l_version pls_integer := 1;
    begin
      while p_len > l_qr_config( l_version )( p_eclevel )( p_mode )
      loop
        l_version := l_version + 1;
      end loop;
      return l_version;
    end get_version;
    --
    procedure add_byte_data( p_val raw, p_version pls_integer, p_stream in out nocopy tp_bits )
    is
      l_len pls_integer := utl_raw.length( p_val );
    begin
      append_bits( p_stream, 4, 4 );  -- byte mode
      append_bits( p_stream, l_len, case when p_version <= 9 then 8 else 16 end );
      for i in 1 .. l_len
      loop
        append_bits( p_stream, to_number( utl_raw.substr( p_val, i, 1 ), 'xx' ), 8 );
      end loop;
    end add_byte_data;
    --
  begin
    l_eclevel := case upper( p_ec_level )
                   when 'L' then 1
                   when 'M' then 2
                   when 'Q' then 3
                   when 'H' then 4
                   else 2
                 end;
    l_qr_config := get_qr_config;
    --
    if translate( p_val, '#0123456789', '#' ) is null
    then  -- numeric mode
      l_version := get_version( length( p_val ), l_eclevel, 3 );
      append_bits( l_stream, 1, 4 ); -- mode
      append_bits( l_stream, length( p_val )
                 , case
                     when l_version <= 9 then 10
                     when l_version <= 26 then 12
                     else 14
                   end
                 );
      for i in 1 .. trunc( length( p_val ) / 3 )
      loop
        append_bits( l_stream, substr( p_val, i * 3 - 2, 3 ), 10 );
      end loop;
      case mod( length( p_val ), 3 )
        when 1 then append_bits( l_stream, substr( p_val, -1 ), 4 );
        when 2 then append_bits( l_stream, substr( p_val, -2 ), 7 );
        else null;
      end case;
    elsif translate( p_val, '#0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:', '#' ) is null
    then -- alphanumeric mode
      l_version := get_version( length( p_val ), l_eclevel, 4 );
      append_bits( l_stream, 2, 4 ); -- mode
      append_bits( l_stream, length( p_val )
                 , case
                     when l_version <= 9 then 9
                     when l_version <= 26 then 11
                     else 13
                   end
                 );
      l_tmp := utl_raw.translate( utl_raw.cast_to_raw( p_val )
                                , utl_raw.concat( utl_raw.xrange( '30', '39' )
                                                , utl_raw.xrange( '41', '5A' )
                                                , '2024252A2B2D2E2F3A'
                                                )
                                , utl_raw.xrange( '00', '2C' )
                                );
      for i in 1 .. trunc( length( p_val ) / 2 )
      loop
        append_bits( l_stream
                   , to_number( utl_raw.substr( l_tmp, i * 2 - 1, 1 ), 'xx' ) * 45
                   + to_number( utl_raw.substr( l_tmp, i * 2, 1 ), 'xx' )
                   , 11
                   );
      end loop;
      if mod( length( p_val ), 2 ) = 1
      then
        append_bits( l_stream, to_number( utl_raw.substr( l_tmp, -1 ), 'xx' ), 6 );
      end if;
    elsif utl_i18n.raw_to_char( utl_i18n.string_to_raw( p_val, 'US7ASCII' ), 'US7ASCII' ) = p_val
    then -- byte mode
      l_version := get_version( length( p_val ), l_eclevel, 5 );
      l_tmp := utl_i18n.string_to_raw( p_val, 'US7ASCII' );
      add_byte_data( l_tmp, l_version, l_stream );
    else -- ECI mode
      append_bits( l_stream, 7, 4 );  -- ECI mode
      append_bits( l_stream, 26, 8 ); -- ECI Assignment number 26 = UTF8
      l_tmp := utl_i18n.string_to_raw( p_val, 'AL32UTF8' );
      l_version := get_version( utl_raw.length( l_tmp ), l_eclevel, 6 );
      add_byte_data( l_tmp, l_version, l_stream );
    end if;
    -- terminator
    l_sz := l_qr_config( l_version )( l_eclevel )( 1 ) * 8;
    for i in 1 .. 4
    loop
      if l_stream.count < l_sz
      then
        append_bits( l_stream, 0, 1 );
      end if;
    end loop;
    -- 8-bit alignment
    if mod( l_stream.count, 8 ) > 0
    then
      append_bits( l_stream, 0, 8 - mod( l_stream.count, 8 ) );
    end if;
    -- padding
    l_len := l_stream.count;
    loop
      exit when l_len >= l_sz;
      append_bits( l_stream, 236, 8 );
      l_len := l_len + 8;
      exit when l_len >= l_sz;
      append_bits( l_stream, 17, 8 );
      l_len := l_len + 8;
    end loop;
    --
    declare
      l_data      tp_bits;
      l_ecc       tp_bits;
      l_blocks    pls_integer;
      l_block_idx pls_integer;
      l_ec_bytes  pls_integer;
      l_dw_bytes  pls_integer;
      l_offs      pls_integer;
      l_noffs     pls_integer;
      l_eoffs     pls_integer;
      l_block tp_bits;
      l_new   tp_bits;
    begin
      l_blocks := l_qr_config( l_version)( l_eclevel )( 8 );
      if l_qr_config( l_version)( l_eclevel )( 7 ) > 1
      then
        l_blocks := l_blocks + l_qr_config( l_version)( l_eclevel )( 10 );
      end if;
      l_ec_bytes := l_qr_config( l_version)( l_eclevel )( 2 ) / l_blocks;
      l_data := bitstoword( l_stream, 8 );
      l_offs := 0;
      l_noffs := 0;
      l_block_idx := 0;
      l_eoffs := l_qr_config( l_version)( l_eclevel )( 1 );
      for i in 1 .. l_qr_config( l_version)( l_eclevel )( 7 )
      loop
        l_dw_bytes := l_qr_config( l_version)( l_eclevel )( 7 + i * 2 );
        for j in 1 .. l_qr_config( l_version)( l_eclevel )( 6 + i * 2 )
        loop
          l_noffs := l_block_idx;
          for x in 0 .. l_dw_bytes - 1
          loop
            l_block( x ) := l_data( x + l_offs );
            l_new( l_noffs ) := l_block( x );
            if i > 1 and x >= l_qr_config( l_version)( l_eclevel )( 9 ) - 1
            then
              l_noffs := l_noffs + l_qr_config( l_version)( l_eclevel )( 10 );
            else
              l_noffs := l_noffs + l_blocks;
            end if;
          end loop;
          l_offs := l_offs + l_dw_bytes;
          l_ecc := reed_solomon( l_block, 285, 256, l_ec_bytes, 0 );
          for x in 0 .. l_ec_bytes - 1
          loop
            l_new( l_eoffs + l_block_idx + x * l_blocks ) := l_ecc( x );
          end loop;
          l_block.delete;
          l_ecc.delete;
          l_block_idx := l_block_idx + 1;
        end loop;
      end loop;
          l_stream.delete;
          for i in l_new.first .. l_new.last
          loop
            append_bits( l_stream, l_new( i ), 8 );
          end loop;
    end;
    --
    add_patterns( l_version, p_matrix );
    add_stream( 4 * l_version + 17, l_stream, p_matrix );
    --
    l_stream.delete;
    --
    declare
      l_width pls_integer := 4 * l_version + 17;
      l_mask pls_integer;
      l_hbit pls_integer;
      l_hcnt pls_integer;
      l_vbit pls_integer;
      l_vcnt pls_integer;
      masked tp_matrix;
      n1 pls_integer;
      n2 pls_integer;
      n3 pls_integer;
      n4 pls_integer;
      best number;
      score number;
    function mask_function( f pls_integer
                          , i pls_integer
                          , j pls_integer
                          )
    return pls_integer
    is
    begin
      return nvl( case
                    when f = 0 and mod( i+j, 2 ) = 0 then 1
                    when f = 1 and mod( i, 2 ) = 0 then 1
                    when f = 2 and mod( j, 3 ) = 0 then 1
                    when f = 3 and mod( i+j, 3 ) = 0 then 1
                    when f = 4 and mod(trunc(i/2)+trunc(j/3),2) = 0 then 1
                    when f = 5 and mod(i*j,2) + mod(i*j,3) = 0 then 1
                    when f = 6 and mod(mod(i*j,2) + mod(i*j,3), 2 ) = 0 then 1
                    when f = 7 and mod(mod(i*j,3) + mod(i+j,2), 2 ) = 0 then 1
                  end
                , 0
                );
    end;
    --
    procedure mask_matrix
      ( p_mat tp_matrix
      , p_masked in out nocopy tp_matrix
      , p_mask pls_integer
      )
    is
      t_info pls_integer;
    begin
      for y in 0 .. l_width - 1
      loop
        for x in 0 .. l_width - 1
        loop
          if p_mat( y )( x ) > 127
          then
            p_masked( y )( x ) := bitxor( p_mat( y )( x ) - 128, mask_function( p_mask, x, y ) );
          else
            p_masked( y )( x ) := p_mat( y )( x );
          end if;
        end loop;
      end loop;
      t_info := get_formatinfo( l_eclevel, p_mask );
      for i in 0 .. 5
      loop
        p_masked(i)(8) := sign( bitand( t_info, power( 2, 14 - i ) ) );
        p_masked(8)(i) := sign( bitand( t_info, power( 2, i ) ) );
      end loop;
      p_masked(7)(8) := sign( bitand( t_info, power( 2, 8 ) ) );
      p_masked(8)(8) := sign( bitand( t_info, power( 2, 7 ) ) );
      p_masked(8)(7) := sign( bitand( t_info, power( 2, 6 ) ) );
      for i in 0 .. 6
      loop
        p_masked(8)(l_width-1-i) := sign( bitand( t_info, power( 2, 14 - i ) ) );
        p_masked(l_width-1-i)(8) := sign( bitand( t_info, power( 2, i ) ) );
      end loop;
      p_masked(l_width - 8)(8) := sign( bitand( t_info, power( 2, 7 ) ) );
    end;
    --
    procedure score_rule1( p_cnt pls_integer )
    is
    begin
      if p_cnt >= 5
      then
        n1 := n1 + 3 + p_cnt - 5;
      end if;
    end;
    --
    procedure rule1( p_bit pls_integer
                   , p_prev in out pls_integer
                   , p_cnt in out pls_integer
                   )
    is
    begin
      if p_bit = p_prev
      then
        p_cnt := p_cnt + 1;
      else
        score_rule1( p_cnt );
        p_prev := p_bit;
        p_cnt := 1;
      end if;
    end;
    --
    procedure rule3( p_x pls_integer, p_y pls_integer, p_xy boolean )
    is
      function gfm( p pls_integer )
      return pls_integer
      is
      begin
        return sign( case when p_xy
                       then masked( p_y )( p_x + p )
                       else masked( p_y + p )( p_x )
                     end
                   );
      end;
    begin
      if (   case when p_xy then p_x else p_y end >= 6
         and gfm( - 6 ) = 1
         and gfm( - 5 ) = 0
         and gfm( - 4 ) = 1
         and gfm( - 3 ) = 1
         and gfm( - 2 ) = 1
         and gfm( - 1 ) = 0
         and gfm( 0 ) = 1
         and (  (   case when p_xy then p_x else p_y end >= 10
                and gfm( - 7 ) + gfm( - 8 ) + gfm( - 9 ) + gfm( - 10 ) = 0
                )
             or (   case when p_xy then p_x else p_y end <= l_width - 5
                and  gfm( 1 ) + gfm( 2 ) + gfm( 3 ) + gfm( 4 ) = 0
                )
             )
         )
      then
        n3 := n3 + 1;
      end if;
    end;
    --
    begin
      begin
        best := 99999999;
        for m in 0 .. 7
        loop
          mask_matrix( p_matrix, masked, m );
          n1 := 0;
          n2 := 0;
          n3 := 0;
          n4 := 0;
          for y in 0 .. l_width - 1
          loop
            l_hbit := -1;
            l_hcnt := 0;
            l_vbit := -1;
            l_vcnt := 0;
            for x in 0 .. l_width - 1
            loop
              rule1( sign( masked(y)(x) ), l_hbit, l_hcnt );
              rule1( sign( masked(x)(y) ), l_vbit, l_vcnt );
              --
              if ( x > 0 and y > 0
                 and ( sign( masked(y)(x) ) + sign( masked(y)(x-1) )
                     + sign( masked(y-1)(x) ) + sign( masked(y-1)(x-1) )
                     ) in ( 0, 4 )
                 )
              then
                n2 := n2 + 1;
              end if;
              --
              rule3( x, y, true );
              rule3( x, y, false );
              --
              n4 := n4 + sign( masked(y)(x) );
            end loop;
            score_rule1( l_hcnt );
            score_rule1( l_vcnt );
          end loop;
          n4 := trunc( 10 * abs( n4 * 2 - l_width * l_width ) / ( l_width * l_width ) );
          score := n1 + n2 * 3 + n3 * 40 + n4 * 10;
          if score < best
          then
            l_mask := m;
            best := score;
          end if;
        end loop;
      end;
      mask_matrix( p_matrix, p_matrix, l_mask );
    end;
    --
    add_quiet( p_matrix, 4 );
    --
  end gen_qrcode_matrix;
-- ===========================================================================
-- PORTED FROM as_barcode (MIT) — end
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- PRIVATE: encode p_value and validate, raising c_err_barcode on failure
-- ---------------------------------------------------------------------------
  PROCEDURE encode_qr(p_value    IN VARCHAR2,
                      p_ec_level IN VARCHAR2,
                      p_matrix   OUT tp_matrix) IS
  BEGIN
    IF p_value IS NULL THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_barcode,
        'QR code value must not be NULL');
    END IF;
    BEGIN
      gen_qrcode_matrix(p_value, p_ec_level, p_matrix);
    EXCEPTION WHEN OTHERS THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_barcode,
        'QR encoding failed — value may exceed the capacity of QR version 40'
        || ' at EC level ' || NVL(UPPER(p_ec_level), 'M')
        || ' (' || SQLERRM || ')');
    END;
  END encode_qr;

-- ---------------------------------------------------------------------------
-- qrcode — draw a QR code as filled vector rectangles
-- ---------------------------------------------------------------------------
  PROCEDURE qrcode(p_doc      IN rad_pdf_types.t_doc_handle,
                   p_value    IN VARCHAR2,
                   p_x        IN NUMBER,
                   p_y        IN NUMBER,
                   p_size     IN NUMBER,
                   p_ec_level IN VARCHAR2              DEFAULT 'M',
                   p_color    IN rad_pdf_types.t_rgb  DEFAULT '000000',
                   p_unit     IN rad_pdf_types.t_unit DEFAULT 'pt') IS
    l_matrix tp_matrix;
    l_n      PLS_INTEGER;
    l_x0     NUMBER;
    l_y0     NUMBER;
    l_size   NUMBER;
    l_m      NUMBER;                       -- module size in pt
    l_path   rad_pdf_types.t_path;
    l_run    PLS_INTEGER;
    l_rx     NUMBER;
    l_ry     NUMBER;

    -- Append one filled rectangle (a run of dark modules) as a subpath.
    -- Rows overlap upward by 0.5% of a module so screen rasterizers do not
    -- show anti-aliasing hairlines between adjacent fills (QR decoders
    -- sample module centres, so the bleed is harmless).
    PROCEDURE add_rect(p_rx IN NUMBER, p_ry IN NUMBER, p_rw IN NUMBER) IS
      l_i PLS_INTEGER := l_path.COUNT;
      l_h NUMBER      := l_m * 1.005;
      l_e rad_pdf_types.t_path_element;   -- fresh record, all fields NULL
    BEGIN
      l_e.element_type := rad_pdf_types.c_move_to;
      l_e.x1 := p_rx;        l_e.y1 := p_ry;        l_path(l_i)     := l_e;
      l_e.element_type := rad_pdf_types.c_line_to;
      l_e.x1 := p_rx + p_rw;                        l_path(l_i + 1) := l_e;
      l_e.y1 := p_ry + l_h;                         l_path(l_i + 2) := l_e;
      l_e.x1 := p_rx;                               l_path(l_i + 3) := l_e;
      l_e.element_type := rad_pdf_types.c_close;
      l_e.x1 := NULL;        l_e.y1 := NULL;        l_path(l_i + 4) := l_e;
    END add_rect;
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    IF NVL(p_size, 0) <= 0 THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_barcode,
        'QR code size must be > 0');
    END IF;
    encode_qr(p_value, p_ec_level, l_matrix);

    l_n    := l_matrix.COUNT;              -- modules per side, quiet included
    l_x0   := rad_pdf_units.to_pt(p_x,    p_unit);
    l_y0   := rad_pdf_units.to_pt(p_y,    p_unit);
    l_size := rad_pdf_units.to_pt(p_size, p_unit);
    l_m    := l_size / l_n;

    -- One rad_pdf_canvas.path call per matrix row keeps every content-stream
    -- block far below the 32k VARCHAR2 limit even for QR version 40.
    -- Runs of adjacent dark modules in a row merge into a single rectangle.
    FOR r IN 0 .. l_n - 1 LOOP             -- r = row, top to bottom
      l_path.DELETE;
      l_run := 0;
      l_ry  := l_y0 + l_size - (r + 1) * l_m;
      FOR c IN 0 .. l_n - 1 LOOP           -- c = column, left to right
        IF l_matrix(c)(r) > 0 THEN
          IF l_run = 0 THEN
            l_rx := l_x0 + c * l_m;
          END IF;
          l_run := l_run + 1;
        ELSIF l_run > 0 THEN
          add_rect(l_rx, l_ry, l_run * l_m);
          l_run := 0;
        END IF;
      END LOOP;
      IF l_run > 0 THEN
        add_rect(l_rx, l_ry, l_run * l_m);
      END IF;
      IF l_path.COUNT > 0 THEN
        rad_pdf_canvas.path(p_doc, l_path,
                            p_line_color => NULL,
                            p_fill_color => NVL(p_color, '000000'));
      END IF;
    END LOOP;
  END qrcode;

-- ---------------------------------------------------------------------------
-- qrcode_modules — modules per side (quiet zone included)
-- ---------------------------------------------------------------------------
  FUNCTION qrcode_modules(p_value    IN VARCHAR2,
                          p_ec_level IN VARCHAR2 DEFAULT 'M')
    RETURN PLS_INTEGER IS
    l_matrix tp_matrix;
  BEGIN
    encode_qr(p_value, p_ec_level, l_matrix);
    RETURN l_matrix.COUNT;
  END qrcode_modules;

END rad_pdf_barcode;
/
